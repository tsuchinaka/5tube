# Arquitectura de 5Tube

El tweak está partido por responsabilidades. `Tweak.m` solo arranca; cada
módulo de `Core/` tiene una tarea y un header.

## Capas

| Archivo | Responsabilidad |
| --- | --- |
| `Tweak.m` | constructor, caches, arranque del proxy y de los hooks |
| `5Tube.h` | paraguas de imports y headers |
| `Core/YTCommon` | logging, preferencias, strings, IDs, crash handler, runtime |
| `Core/YTAPI` | contextos y POST a InnerTube |
| `Core/YTFeed` | modelo de video, collectors, Atom, paginación, listas |
| `Core/YTPlayer` | selección de streams, remux, proxy HTTP, iconos, SRT |
| `Core/YTCaptions` | pistas, parser, SRT, overlay y botón CC |
| `Core/YTActions` | like, favoritos, suscripciones, playlists, comentarios, historial |
| `Core/YTTrending` | sección Trending creada en runtime |
| `Core/YTHooks` | NSURLProtocol, cargador de feeds, hooks de app y player |
| `YTAuth.m` | device code, token, refresh, estado de cuenta |
| `YTMux.m` | remux MP4 de video y audio |

## Dependencias

```
Tweak
  ├─ YTCommon
  ├─ YTAPI ── YTCommon, YTAuth
  ├─ YTFeed ── YTCommon, YTAPI, YTAuth, YTPlayer
  ├─ YTPlayer ── YTCommon, YTAPI, YTCaptions, YTMux
  ├─ YTCaptions ── YTCommon, YTAPI
  ├─ YTActions ── YTCommon, YTAPI, YTFeed, YTAuth
  ├─ YTTrending ── YTCommon
  └─ YTHooks ── YTCommon, YTFeed, YTPlayer, YTCaptions, YTActions, YTTrending
```

Los headers no se incluyen entre sí: `5Tube.h` los importa en orden y cada
`.m` importa solo `5Tube.h`. Así no hay ciclos.

## Flujo de un feed

1. La app crea un `YTSearchRequest` y pide una URL GData.
2. `YTHooks` reconoce la URL y llama a `YTAtomForRequest`.
3. `YTFeed` construye los items y `YTEntry` los convierte en Atom.
4. `YTHooks` termina la carga y el parser de la app crea los `YTVideo`.

## Flujo del player

1. `YTFeed` arma la entrada con `YTPlayURL`.
2. `YTPlayer` pide `player` a InnerTube y elige el mejor H.264 compatible.
3. El proxy sirve `/<id>.mp4` con Range y remuxea video + audio con `YTMux`.
4. Para un directo, `YTEntry` apunta a `/live/<id>.m3u8`; el proxy pide el
   `player`, cachea el HLS y sirve solo variantes de 720p30 o menos.
5. `YTCaptions` baja el track firmado y pinta los cues sobre el player.

## Reglas

- Una función compartida se declara en su header; no hay `static` cruzado.
- Un módulo no importa el `.m` de otro.
- El logging y las preferencias van por `YTCommon`.
- Las llamadas a InnerTube van por `YTAPI`.
- Los hooks se instalan en `YTHooksInstall` o en `YTHookSAX`.
- Las clases que heredan del framework se crean con `objc_allocateClassPair`.

## Estado

- 0.2.0, instalado.
- Misma funcionalidad que 0.1.33, reorganizada.
