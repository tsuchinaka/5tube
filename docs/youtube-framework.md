# YouTube 5.1: app y framework

Notas de ingeniería inversa sobre `YouTube.app` (1.0, iOS 5.1.1) y
`/System/Library/PrivateFrameworks/YouTube.framework/YouTube`. El framework no
existe como archivo en disco: vive en `dyld_shared_cache_armv7`.

## Reparto de responsabilidades

La app es casi toda interfaz. El framework es red, modelo, parser, auth y
reproductor.

| Capa | App | Framework |
| --- | --- | --- |
| Arranque | `YTApplication`, `YTController` | — |
| Navegación | `YTContentView`, `YTCategoryController` | — |
| Secciones | `YTFeaturedCategoryController`, `YTMostViewedCategoryController`, `YTHistoryCategoryController`, `YTMyVideosCategoryController`, `YTSubscriptionListCategoryController`, `YTPlaylistListCategoryController` | — |
| Datos | `dataSourceClass` de cada controlador | `YTVideoDataSource` y sus subclases |
| Red | — | `YTSearchRequest`, `YTFeedRequest`, `XMLSAXHTTPRequest` |
| Modelo | — | `YTVideo`, `YTVideoReference`, `YTPersistentVideoList` |
| Auth | popups de `YTController` | `YTAuthenticator`, `YTAccountAuthenticator`, `YTDeviceAuthenticator` |
| Acciones | botones y hojas | `YTAuthenticatedAccountPost`, `YTSubscriptionsRequest`, `YTAccountFeedRequest` |
| Imágenes | celdas | `YTImageLoader`, `YTImageLoad` |
| Player | `YTVideoCategoryView`, `YTContentView` | `YTMovieView`, `YTVideoReference` |
| Subtítulos | — | `YTCaptionsRequest`, `YTCaptionTrack` |

Los controladores de video (`YTFeaturedCategoryController`,
`YTMostViewedCategoryController`, `YTHistoryCategoryController`, ...) solo
declaran `+dataSourceClass`. Toda la lógica de feeds está en el framework.

## Flujo de un feed

1. El controlador de categoría crea su data source (`YTFeaturedVideoDataSource`,
   `YTHistoryVideoDataSource`, ...).
2. El data source crea un `YTSearchRequest` y llama a un método
   `searchFor...:withDelegate:`.
3. El request arma una URL `http://gdata.youtube.com/feeds/api/...`.
4. `XMLSAXHTTPRequest` descarga y parsea Atom con SAX de libxml2.
5. Las entradas se convierten en `YTVideo` y se guardan en `_videos`.
6. `YTFeedRequest didParseData` avisa al delegado y la tabla se recarga.

El tweak corta el paso 3: `YTShouldHandle` reconoce `gdata.youtube.com` y
`/feeds/api/`, y `YTAtomForRequest` devuelve Atom construido desde InnerTube.
La app sigue usando su parser y sus pantallas.

## Estado en la app

Las clases de UI que importan para enganchar:

- `YTContentView`: `_categoryControllers`, `_activeController`, `_searchField`,
  `_delayedAddToHistoryVideo`, `_unifiedView`. Registra las secciones.
- `YTController`: `_playingVideo`, `_ratingPost`, `_playlistPost`,
  `_loginPopup`, `_errorPopup`, `_captchaURL`, `_movieView`.
- `YTVideoCategoryController`: `_view`, `_isCurrentCategory`, `_avoidReloads`,
  `_shouldReloadCategory`.
- `YTVideoCategoryView`: tabla, celdas y botón de cargar más.
- `YTHistoryCategoryController`: `_clearHistorySheet` y los botones de borrar.
- `YTPlaylistListCategoryController`: `_createPlaylistPost`, `_addPlaylistView`,
  `_previouslySelectedPlaylist`.
- `YTSubscriptionListCategoryController`: `_subscribeToUser`,
  `_createSubscriptionPost`, `_removeSubscriptionPost`.
- `YTTimeQualifiedCategoryController`: `_segmentedControl` y `_timeQualifier`;
  de aquí salen Today, This Week y All.
- `YTVideoUnifiedView`: transición entre lista y player.

## Clases del framework

Auth y red:

- `YTAuthenticator`, `YTAccountAuthenticator`, `YTDeviceAuthenticator`
- `YTAuthenticatorDeferredRequest`
- `YTSearchRequest`, `YTFeedRequest`, `YTAccountFeedRequest`, `YTCommentsRequest`
- `YTSubscriptionsRequest`, `YTCategoriesRequest`, `YTSearchSuggestionsRequest`
- `YTMutableURLRequest`, `XMLSAXHTTPRequest`
- `YTNetworkController`, `YTWebServiceConfig`, `YTBase64`, `YTProtectedDefaults`

Modelo y datos:

- `YTVideo`, `YTVideoReference`, `YTPersistentVideoList`
- `YTVideoDataSource`
- `YTMyVideosVideoDataSource`, `YTRecentlyAddedVideoDataSource`,
  `YTSearchVideoDataSource`, `YTBookmarksVideoDataSource`,
  `YTSubscriptionsVideoDataSource`, `YTHistoryVideoDataSource`,
  `YTRelatedVideoDataSource`, `YTMoreByAuthorVideoDataSource`,
  `YTFeaturedVideoDataSource`, `YTMostViewedVideoDataSource`,
  `YTTimeQualifiedVideoDataSource`, `YTTopRatedVideoDataSource`

UI y media:

- `YTMovieView`, `UIMovieBackgroundView`
- `YTImageLoader`, `YTImageLoad`
- `YTCaptionTrack`, `YTCaptionTrackRequest`, `YTCaptioningCache`
- `YTFavoritesController`

## Autenticación

El framework original usa dos caminos muertos:

- `https://www.google.com/youtube/accounts/applelogin1` y `applelogin2`
- `https://www.google.com/youtube/accounts/ClientLogin` con
  `Email=...&Passwd=...&service=youtube&source=YouTubeAPI`

Los dos devuelven error. `YTDeviceAuthenticator` envuelve el flujo de
`youtube.com/activate` con un device code, y es el que el tweak usa.

Puntos útiles:

- `-[YTAuthenticator isAccountAuthenticated]` se puede devolver desde el token
  de preferencias.
- `setAccount:`, `setAccountYouTubeName:`, `setAccountToken:`,
  `setAccountTokenDate:` dejan la UI en estado firmado.
- `YTAccountAuthenticatorDidAuthenticateNotification` refresca la interfaz.
- El token de InnerTube no sirve para el cliente ANDROID del player: ese cliente
  responde 400 con `Authorization: Bearer`. El player va sin token.
- El token sí sirve para `browse` con el cliente TV y para las acciones de
  cuenta.

## Endpoints GData que usa el framework

Todos pasan por el tweak.

| Uso | URL |
| --- | --- |
| Búsqueda | `/feeds/api/videos/?q=...&orderby=relevance` |
| Relacionados | `/feeds/api/videos/<id>/related` |
| Subidas de un canal | `/feeds/api/users/<id>/uploads` |
| Subidas propias | `/feeds/api/users/default/uploads` |
| Favoritos | `/feeds/api/users/default/favorites` |
| Suscripciones | `/feeds/api/users/default/subscriptions?max-results=50` |
| Playlists | `/feeds/api/users/default/playlists` |
| Historial | `/feeds/api/users/default/watch_history` |
| Novedades de suscripción | `/feeds/api/users/default/newsubscriptionvideos` |
| Destacados | `/feeds/api/standardfeeds/<país>/recently_featured` |
| Más vistos | `/feeds/api/standardfeeds/<país>/most_viewed&time=...` |
| Mejor valorados | `/feeds/api/standardfeeds/<país>/top_rated` |
| Detalle | `/feeds/api/videos/<id>` |
| Lote | `/feeds/api/videos/batch` |
| Comentarios | petición `next` + `comment/create_comment` |
| Subtítulos | `youtube.com/api/timedtext` |
| Sugerencias | `suggestqueries.google.com` |

`time` acepta `today`, `this_week` y `all_time`. El framework tiene las tres
cadenas en el binario; el tweak mapea las tres a búsquedas ordenadas por vistas.

## Acciones de cuenta

Funcionan con el cliente TV y el token de OAuth:

- like / dislike (`like/like`, `like/dislike`)
- favoritos (se mapean a like)
- suscribir / borrar suscripción
- añadir video a playlist (`browse/edit_playlist`)
- comentar (`comment/create_comment`, con `createCommentParams` de `next`)

No funciona:

- crear playlist (`playlist/create` devuelve 400 `Precondition check failed`)
- Data API v3 (el client no tiene acceso)
- charts (`FEtrending`) y categorías (400)
- subir video (el flujo GData de `uploads.gdata.youtube.com` está muerto)

## Player y calidades

`YTMovieView` usa `MPMoviePlayerController`. El chip es un A4 (iPhone 4):

- H.264 hasta 720p30, perfil Main o High nivel 3.1.
- 1080p, 720p60 y perfiles level 4.0 no son fiables.
- VP9 y AV1 no se decodifican.
- Audio AAC-LC; Opus no.

El tweak pide `player` al cliente ANDROID sin token, elige el mejor stream
H.264 con `height <= 720` y `fps <= 30`, y remuxea video + audio AAC en
`/var/tmp/yt720-<id>.mp4`. Si no hay 720p30, usa 480p; si no, el progresivo 360p.
El proxy local sirve por HTTP con Range.

## Qué se puede hacer

- Reemplazar cualquier feed GData interceptando `NSURLProtocol` o
  `XMLSAXHTTPRequest`.
- Añadir secciones nuevas subclaseando `YTVideoCategoryController` y
  devolviendo un `dataSourceClass`.
- Cambiar el orden, los filtros y la paginación en `YTAtomForRequest`.
- Sustituir iconos, miniaturas y textos de las celdas.
- Enganchar botones de la app (`setRating:forVideo:`, `postComment:forVideo:`,
  `subscribeToUser:`, `addVideo:toPlaylist:`).
- Cambiar el player y el formato servido.
- Leer y escribir el modelo `YTVideo` desde los hooks.
- Usar notificaciones del framework para refrescar pantallas.

## Qué no se puede o no conviene

- Revivir ClientLogin o applelogin: los endpoints ya no existen.
- Subir videos: el flujo depende de GData y de un XML de subida retirado.
- Crear playlists con el cliente actual: 400 del servidor.
- Añadir codecs o 1080p: límite del decodificador, no del tweak.
- Reescribir pantallas complejas sin tocar UIKit: la app es cerrada y sin
  headers; cada clase nueva hay que crearla a mano.
- Confiar en ivars privados: cambian de offset y muchos son `assign`.
- Usar `object_setIvar` con objetos bajo ARC sin retener: deja punteros
  colgando. Fue el crash de History.
- Mantener viva una petición después de cerrar la pantalla: el delegado de
  `YTSearchRequest` no se retiene y termina recibiendo memoria reciclada.

## Zonas peligrosas

- `YTSearchRequest`: el delegado es `assign`. Si la pantalla muere, la petición
  le habla a memoria liberada. Retener el data source mientras vive la petición.
- `YTVideoDataSource`: `_videos`, `_history`, `_searchRequest`. Escribir ivars a
  mano corrompe el data source. Usar `_clearVideos` y dejar que el parser llene.
- `XMLSAXHTTPRequest`: el parseo termina en el hilo principal. Un feed grande
  bloquea la UI.
- `YTImageLoader`: caché en disco (`YouTube/VideoCache`); las URLs con protocolo
  relativo (`//yt3...`) fallan en iOS 5.
- `YTMovieView`: el player no tolera un `play` sin URL válida; el proxy debe
  devolver 200/206 o 404 limpio.
- `YTPersistentVideoList`: guarda historial local en plist; un objeto corrupto
  tumba History al recargar.

## Cómo añadir una sección

1. Subclase de `YTVideoCategoryController` en el tweak.
2. `+dataSourceClass` devuelve una subclase de `YTVideoDataSource`.
3. El data source pide su feed con `YTSearchRequest`.
4. `YTAtomForRequest` reconoce la URL y devuelve Atom.
5. Registrar el controlador en `YTContentView` (ivar `_categoryControllers`).

Para una sección sin UI nueva, es más barato reutilizar un controlador
existente y cambiar solo el feed.

## Estado del tweak

- `com.sokubit.5tube` 0.1.32.
- Login migrado desde `com.bytebox.youtubeinnertube`.
- Featured: `FEwhat_to_watch` con sesión; most viewed de la semana sin sesión.
- Most viewed: `today`, `this_week`, `all_time`.
- Suscripciones: icono de canal; New Videos conserva thumbnail.
- Playlists: conteo real del overlay.
- History y My Videos: data source nativo, sin petición manual que dejaba el
  delegado colgando.
- Trending: fila en More, clases creadas en runtime, opt-in con `trendingSection`.
- Captions: la app no tiene UI ni una sola cadena de subtítulos. El tweak pide
  las pistas al `player` de InnerTube (el endpoint `api/timedtext?type=list`
  devuelve 200 con cuerpo vacío), las sirve como `.srt` y dibuja un overlay con
  botón CC. Opt-in con `captionOverlay` mientras se valida el feed.
- Acciones: postean `YTVideoDidChangeNotification`,
  `YTVideoBookmarksDidChangeNotification` y `YTPlaylistsDidChangeNotification`.
