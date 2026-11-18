# Handoff — 5Tube

Tweak para la YouTube stock de iOS 5.1. Repo https://github.com/tsuchinaka/5tube, rama `master`.

## Estado

- Paquete `com.sokubit.5tube`, `control` 0.4.0, nombre 5Tube. Instalado y probado en el dispositivo.
- Último commit y push: `b768bed`. Árbol limpio.
- Tweak `5Tube.dylib` en `/Library/MobileSubstrate/DynamicLibraries/`. Filtro `5Tube.plist` solo `com.apple.youtube`.
- Bundle de ajustes `5TubePrefs`, id `com.sokubit.5tube.prefs`.
- Dispositivo: `root@192.168.0.12`, contraseña `alpine`. El SSH es viejo: hace falta `HostKeyAlgorithms=+ssh-rsa` y `PubkeyAcceptedAlgorithms=+ssh-rsa`.
- Build: `export THEOS=/home/main/theos && make -j4 package`. Target `iphone:clang:5.1:5.1`, armv7.

## Qué hace

- Sustituye los feeds GData muertos (`gdata.youtube.com/feeds/api`) por Atom construido desde InnerTube. La app stock conserva sus pantallas y su parser.
- Proxies locales en `http://127.0.0.1:8765/`: `<ID>.mp4` (720p30 remuxado), `<ID>.360.mp4` (itag 18), HLS para directos e iconos de canal.
- Búsqueda, relacionados, canales, favoritos, suscripciones, historial, playlists y novedades de suscripción.
- Login por device code de YouTube TV (`youtube.com/activate`). Token en preferencias `com.sokubit.5tube`.
- Acciones enganchadas: like/dislike, favoritos, suscribir, borrar suscripción, añadir a playlist y publicar comentario.
- Shorts filtrados sin interruptor.
- Directos por HLS local con una sola variante buena (≤720p30).
- Videos de 1h o más arrancan en el progresivo 360 y no se guardan como último visto.

## Comentarios (cerrado en 0.4.0)

La vista de comentarios no usa el parser SAX del framework. Cadena real:

1. `YTCommentsView _findVideoComments` obtiene `commentsURL` del `YTVideo`.
2. Crea `YTCommentsRequest` y llama `requestMoreComments`.
3. `YTCommentsRequest loadRequest:` entrega la petición a `YTAuthenticator`, que la deja diferida esperando device-auth. Ese estado nunca llega: spinner infinito.
4. Si se salta el autenticador, su parser SAX recibe el Atom pero no produce entradas, así que la vista muestra "No comments".

Lo que hace el tweak ahora:

- `Core/YTActions.m`, `YTHookCommentsLoad`: intercepta `YTCommentsRequest loadRequest:`, obtiene el `videoID` del ivar `_video`, pide los comentarios en background y llama al delegate con `commentsRequest:receivedComments:commentsRemaining:` y un `NSArray` ya listo. No usa XML ni SAX.
- `Core/YTFeed.m`, `YTCommentItems`: pide `next` WEB, recoge las continuaciones, prioriza la de `comments-section`, lee `commentEntityPayload` y devuelve diccionarios con las claves que consume `YTCommentTableViewCell`:
  - `Author`, `Text`, `PublishedDate` (NSDate), `PublishedDateString` (texto relativo como `8 days ago`).
  - Copias en minúscula (`author`, `text`, `date`) por si una ruta antigua las busca así.
- `Core/YTFeed.m`, `YTCommentFeed`: sigue existiendo como Atom de respaldo para la ruta `/comments` de `YTAtomForRequest`, pero la vista ya no pasa por ahí.

Errores que quedaron documentados:

- `next` WEB devuelve 400 si se le manda el bearer de la TV. `Core/YTAPI.m` solo envía token en modo TV o en métodos `comment/`.
- `app:control` con `yt:state name='published'` no es válido y hacía que el parser descartara todas las entradas de búsqueda. Eliminado.
- `YTAuthDidLoad` era una bandera global compartida; con feeds concurrentes una petición podía quedarse sin arrancar. Eliminada.

## Carga de vistas (0.4.0)

Tres causas corregidas:

- `YTListEnter`/`YTListLeave` usaban un único lock global y serializaban todas las peticiones. Ahora hay un `NSRecursiveLock` por clave de feed. `YTPageCache` y `YTTokenCache` quedan protegidos por `YTStoreLock`, tomado solo en accesos cortos.
- `YTStartLoad` limita a 6 peticiones simultáneas con un semáforo.
- Timeout de red global bajado de 25 s a 9 s (`YTPostMode` y `YTGET`).

## Logs y depuración

- Log del tweak: `/var/tmp/ytinner.log`.
- Crash: `/var/tmp/ytinner-crash.txt` y `/var/mobile/Library/Logs/CrashReporter/`.
- Arrancar la app: `su mobile -c "uiopen youtube://"`.
- En el dispositivo no existen `ps`, `tail` ni `wc`.
- Trazas útiles:
  - `comments load <id> <url>`: entró el hook de comentarios.
  - `comments feed <id>`, `comments next N`, `comments page N`, `comments <id> N`: ruta InnerTube.
  - `loadAuth`, `load delivered`, `fail`: feeds normales.
  - `post <método> code <código>`: error de InnerTube con snippet del cuerpo.

## Conocido

- Crear playlist devuelve 400 `Precondition check failed` con este cliente OAuth. El botón no cuelga, pero la lista no se crea.
- Charts (`FEtrending`) y categorías devuelven 400; se sustituyen por búsquedas.
- Data API v3 y subida de video no están disponibles para este cliente.
- El reproductor ANDROID rechaza el bearer de la TV con 400. Las peticiones del player van sin token.
- `YTSearchRequest` guarda el delegate sin retener. `YTStartLoad` lo retiene y `YTFinishLoad` lo suelta.
- Si la app entra en bucle y launchd estrangula YouTube: `sbreload`.

## Pendientes

- Confirmar en pantalla que Rate and comment funciona con la cuenta actual; los comentarios ya cargan, la valoración no se ha probado después de 0.4.0.
- Revisar secciones grandes (Suscripciones, Historial, Playlists) tras el cambio de locks: deben terminar todas, sin spinners cruzados.
- Si alguna vez se quiere usar el Atom de comentarios por otra ruta, el parser SAX del framework exige `feed > entry > author > name`, `published`, `content` y fecha con formato `%Y-%m-%dT%H:%M:%S%z`.

## Documentos relacionados

- `docs/youtube-framework.md`: clases, endpoints, auth y zonas peligrosas.
- `docs/extension-recipes.md`: recetas para feeds, secciones, filtros y botones.
- `docs/ios51-sdk.md`: APIs ausentes y trampas del SDK.
- `docs/architecture.md`: capas y reparto de `Core/`.
- `docs/livestreams-plan.md`: HLS y arranque de 1h+.
