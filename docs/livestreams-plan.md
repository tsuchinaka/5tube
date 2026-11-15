# Plan: livestreams en 5Tube

Estado: implementado en 0.2.2. Gate AVPlayer superado. El proxy
`/live/<id>.m3u8` pide el `player`, cachea el HLS y deja solo variantes de
720p30 o menos. Probado con ABC (720p30), NBC (1080p filtrado) y FOX (720p60
filtrado). Falta la prueba visual dentro de la app.

Objetivo: abrir un directo desde la app stock, reproducirlo con audio y video,
y que las listas no se rompan. Chat, donaciones y encuestas quedan fuera: la
app no tiene UI para eso.

## Lo que ya sabemos

Probado contra InnerTube con el cliente ANDROID y un directo real
(`KQhNZQ_Uag8`, ABC News):

- `playabilityStatus` es `OK`.
- `videoDetails.isLive` y `isLiveContent` son `true`.
- `lengthSeconds` es `0`.
- `streamingData.hlsManifestUrl` viene firmado, con la IP del dispositivo y
  `expire` de unas 6 horas.
- El master HLS tiene 5 variantes: 144p, 240p, 360p, 480p y 720p30.
- Los segmentos son MPEG-TS (`0x47`), no fMP4. Eso es HLS clásico.
- `streamingData.formats` viene vacío; `adaptiveFormats` trae 720p30 o 720p60
  según el canal, pero sin URL progresiva útil.
- El manifiesto incluye pistas de subtítulos `text/vtt`; no son el mismo flujo
  que `captions.playerCaptionsTracklistRenderer`.

Conclusión: la vía es HLS. El proxy MP4 actual no sirve para live: no hay
`itag 18/136` que remuxear.

## Alcance

Dentro:

- Detectar directos en búsqueda, related, suscripciones e historial.
- Mostrar un indicador LIVE en el título.
- Reproducir el HLS en 720p30, 480p o 360p según lo que aguante el A4.
- DVR dentro de la ventana que dé el manifiesto.
- Refrescar la URL si expira.
- Filtrar directos con DRM, edad o miembros.

Fuera:

- Chat, superchat, donaciones, encuestas.
- Latencia baja (el HLS de YouTube va 20-30 s por detrás).
- Anuncios pre-roll: el stream puede traerlos y no hay forma fiable de saltarlos.
- 1080p y 60 fps en el A4.
- Notificaciones push de directos.

## Arquitectura propuesta

### 1. Detección en feeds

`videoRenderer` de un directo trae:

```json
"badges": [{"metadataBadgeRenderer": {
  "icon": {"iconType": "LIVE"},
  "style": "BADGE_STYLE_TYPE_LIVE_NOW",
  "label": "LIVE"
}}]
```

En `Core/YTFeed.m`:

- `YTCollect` marca `item[@"live"] = @YES` si el nodo tiene
  `BADGE_STYLE_TYPE_LIVE_NOW`, `LIVE` o `isLiveNow`.
- `YTCollectTiles` hace lo mismo con `contentType` o `badges` del tile.
- `YTFillSearch` no descarta directos. Hoy descarta los que muestran
  `watching`; hay que cambiarlo para conservar los live y marcar el item.

El item gana dos claves:

- `live`: `1` o ausente.
- `hls`: URL del manifiesto, si ya se conoce.

### 2. Modelo y detalle

`YTDetails` ya pide `player`. Para live:

- Lee `videoDetails.isLive` y `streamingData.hlsManifestUrl`.
- Guarda `live=1`, `hls=<url>`, `length=0`, `seconds=0`,
  `views=viewCount` (espectadores) y `published` como `LIVE`.
- Cachea el HLS por video y expiración. Si la URL tiene menos de 10 minutos,
  se vuelve a pedir.
- Si `playabilityStatus` no es `OK` o hay `licenseInfos`, devuelve `nil` y
  el directo no se ofrece.

`YTEntry` para live:

- `yt:duration seconds='0'`.
- `media:content url='<hls>' type='video/mp4' yt:format='8'`.
- `media:player` con la URL del manifiesto.
- Título con prefijo `● LIVE ` para que la celda lo muestre sin tocar UIKit.

Se usa `127.0.0.1:8765/live/<id>.m3u8`: el proxy pide el `player`, cachea el
manifiesto firmado y lo sirve filtrado. Así el player recibe un HLS local, la
URL se refresca al expirar y se descartan las variantes que el A4 no aguanta.

### 3. Player

`YTFetchUpstream` y `YTPlayURL` deben distinguir live de VOD:

- VOD: flujo actual, proxy MP4 y remux.
- Live: devolver `hlsManifestUrl` y no tocar el proxy.

`YTMovieView`/`UIMoviePlayerController` recibe la URL en `setMoviePath:`.
iOS 5 reproduce HLS con `MPMoviePlayerController`; el gate de la fase 0 lo
confirma. Si el player de YouTube rechaza el manifiesto, el plan B es un proxy
local `/live/<id>.m3u8` que descarga el master, deja solo la variante 720p30 y
reescribe las URLs. Los segmentos se sirven sin tocar.

Duración: `YTFixTime` debe devolver 0 para live y no intentar corregir con
`YTKnownDuration`. La app mostrará 0:00; el título ya dice LIVE.

### 4. Refresco y errores

- El manifiesto caduca. Antes de abrir, si el HLS cacheado tiene menos de 10
  minutos, se pide otro.
- Si el player falla con `NSURLError` 403/410, se descarta el HLS, se pide un
  `player` nuevo y se reintenta una vez.
- Si el directo termina, el manifiesto deja de crecer y el player se detiene.
  Se muestra el error estándar de la app; no hay que inventar UI.
- Los segmentos pueden dar 404 al cortar el directo: el reintento no aplica.

### 5. Filtros

Descartar antes de ofrecer:

- `licenseInfos` o `drm` presente.
- `playabilityStatus` `LOGIN_REQUIRED`, `AGE_VERIFY` o `UNPLAYABLE`.
- Miembros del canal (`membersOnly`).
- Directos privados.

Los directos normales no se filtran por duración; `length=0` es normal.

### 6. UI

La app no tiene badge LIVE. Primera versión: prefijo en el título y `yt:duration=0`.
Segunda versión, si hace falta: enganchar `YTVideoTableViewCell` y pintar un
badge rojo. No es necesario para que funcione.

## Fases

### Fase 0: gate de HLS en iOS 5.1

- Tool mínima con `MPMoviePlayerController` y un live real.
- Log de `loadState`, `playbackState` y error.
- Criterio: reproduce 60 s de audio y video.

Si falla: parar y replantear con proxy de manifiesto o segmentos. No seguir.

### Fase 1: detección y modelo

- `YTCollect` y `YTCollectTiles` marcan `live`.
- `YTDetails` guarda HLS y `live`.
- `YTEntry` emite la URL HLS.
- Criterio: buscar `live news`, abrir un directo y ver `movie <hls>` en el log.

### Fase 2: reproducción

- `YTPlayURL` devuelve HLS para live.
- `YTFixTime` no rompe con 0.
- Criterio: el directo se ve y se oye; no aparece el 404 del proxy.

### Fase 3: refresco y errores

- Cache con expiración.
- Reintento 403/410.
- Criterio: abrir un directo con URL vieja y que arranque igual.

### Fase 4: filtros y título

- DRM, edad, miembros fuera.
- Prefijo LIVE.
- Criterio: un live con DRM no aparece; uno normal sí.

### Fase 5: regresión

- VOD 720p, 480p y 360p.
- Shorts filtrados.
- Captions opt-in sin tocar live.
- Historial, My Videos, playlists, like y subscribe.
- Criterio: nada de lo anterior cambia.

## Pruebas

- Tres directos: 720p30, 720p60 y 1080p. El A4 debe caer a 720p30 o 480p.
- Un directo con DVR: seek hacia atrás dentro de la ventana.
- Un directo que termina: el player se detiene sin crash.
- Un directo age-restricted: no se ofrece.
- Un VOD y un short: sin cambios.
- `curl -I` al manifiesto desde el dispositivo: 200 y `application/vnd.apple.mpegurl`.

## Riesgos

| Riesgo | Mitigación |
| --- | --- |
| El player de YouTube no acepta HLS | Gate fase 0; proxy de manifiesto |
| 720p60 elegido por ABR | Master local con solo 720p30 |
| URL caducada | Cache con expiración y reintento |
| Anuncios en el stream | Aceptar o filtrar por `adPlacements`; no hay salto fiable |
| DRM | Filtrar antes de ofrecer |
| Latencia 20-30 s | Fuera de alcance |
| Chat | Fuera de alcance |

## Archivos que se tocan

- `Core/YTFeed.m`: detección, `YTDetails`, `YTEntry`.
- `Core/YTPlayer.m`: `YTPlayURL`, `YTFetchUpstream`, proxy opcional.
- `Core/YTHooks.m`: `YTFixTime`, `YTAtomForRequest` sin cambios de fondo.
- `Core/YTCommon.m`: helper de expiración si hace falta.
- `docs/youtube-framework.md` y `docs/extension-recipes.md`: estado.

## Estimación

- Fase 0: 1 sesión.
- Fases 1-2: 1-2 sesiones.
- Fase 3: 1 sesión.
- Fase 4-5: 1 sesión.
- Total: 4-5 sesiones con prueba en dispositivo.

## Implementado

- `YTIsLiveNode` detecta `isLiveNow`, `BADGE_STYLE_TYPE_LIVE_NOW` y `LIVE`.
- `YTCollect` y `YTCollectTiles` marcan `live` y prefijan `● LIVE`.
- `YTDetails` lee `isLive`, `hlsManifestUrl` y descarta `licenseInfos`.
- `YTEntry` usa `/live/<id>.m3u8` para live y deja el proxy MP4 para VOD.
- `YTHLSFor` cachea el manifiesto y lo renueva si le quedan menos de 10 min.
- `YTLiveMaster` elimina variantes de más de 720p o más de 30 fps.
- `YTFixTime` convierte `nan`/`inf` en 0 para no romper la duración.
- Validado: el proxy devuelve 200; `hlstest` reproduce el manifiesto del proxy
  y el tiempo avanza; los masters de NBC y FOX salen sin 1080p ni 60 fps.

## Definición de 100%

Un directo aparece en la lista con LIVE, se abre, reproduce audio y video en
720p30 o 480p, permite DVR dentro de la ventana, refresca la URL si caduca y no
rompe VOD, shorts, captions ni las acciones de cuenta. El chat no entra en la
definición porque la app no tiene pantalla para él.
