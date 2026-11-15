# Recetas de extensión

Cómo llevar cada capacidad del framework a código. El estado indica qué ya hace
5Tube 0.1.29.

## 1. Reemplazar un feed GData

Estado: hecho. Punto de entrada: `YTAtomForRequest` en `Core/YTHooks.m`.

El parser original sigue, solo cambia el cuerpo. Añadir una ruta es una rama:

```objc
} else if ([path rangeOfString:@"watch_history"].location != NSNotFound) {
    [items addObjectsFromArray:YTAuthVideos(@"history", @"FEhistory", nil, start + limit)];
}
```

Reglas:

- Detectar por `path` y `query`, no por la URL completa.
- Devolver `YTFeed(items, start, nextURL)` o `YTRawFeed` si el XML es propio.
- Mantener `openSearch:totalResults` inflado para que aparezca Load More.
- Cachear por clave que incluya el filtro (`history`, `chart:today:US`).
- No bloquear el hilo principal: `YTStartLoad` ya corre en la cola global.

## 2. Añadir una sección

Estado: hecho, opt-in (`trendingSection`). La app registra las secciones en
`YTContentView` (`_categoryControllers`) y las pinta en `_buttonBarItems`.

La vía barata: reutilizar un controlador existente y cambiar su feed, como
Featured y Most viewed. La vía completa (las clases del framework se declaran
con `@interface YTVideoCategoryController : UIViewController @end` en el
tweak):

```objc
@interface YTTrendingController : YTVideoCategoryController
@end

@implementation YTTrendingController
+ (Class)dataSourceClass { return [YTTrendingSource class]; }
- (NSString *)name { return @"Trending"; }
- (NSString *)iconName { return @"MostViewed"; }
@end
```

En 5Tube las clases se crean con `objc_allocateClassPair`, no con `@interface`,
porque el tweak no linkea contra YouTube.framework. El data source solo tiene
que pedir su feed:

```objc
@interface YTTrendingSource : YTVideoDataSource
@end

@implementation YTTrendingSource
- (void)reloadData {
    id request = [[NSClassFromString(@"YTSearchRequest") alloc] init];
    [request setDelegate:self];
    [request loadRequest:[NSURLRequest requestWithURL:
        [NSURL URLWithString:@"http://gdata.youtube.com/feeds/api/standardfeeds/US/most_viewed?time=today"]]];
}
@end
```

El registro está en `YTContentView`: `_categoryControllers` y `_buttonBarItems`
deben crecer juntos, y el tab bar necesita un icono que exista en el bundle
(`iconName` devuelve un PNG por nombre). Es la parte más frágil. Para una
función simple, `pushCategoryController:` desde un botón evita tocar el tab bar
y la personalización.

Riesgos:

- Un controlador sin su `UITabBarItem` no se ve.
- `saveViewState` guarda el índice activo; una sección nueva debe sobrevivir a
  la rotación y al relanzamiento.
- `YTCategoryController` espera un `dataSourceClass` válido; si es nil, la
  tabla queda vacía.

## 3. Orden, filtros y paginación

Estado: parcial. Most viewed usa `time`; Featured usa recomendados; la
paginación usa `start-index`.

El contrato:

- `start-index` empieza en 1.
- `max-results` es el tamaño de página.
- `time` vale `today`, `this_week` o `all_time`.
- `orderby` vale `relevance` o `updated`.

Para un filtro nuevo, usar una clave de caché distinta y un `params` de
búsqueda distinto:

```objc
NSString *params = @"CAMSAggC"; // vistas + hoy
NSArray *items = YTFillSearch(@"chart:today:US", @"a", params, @"US", need);
```

`YTFillSearch` ya une páginas con el token de continuación. Si el feed no trae
token, `Load More` no aparece aunque se infle el total. En ese caso, pedir una
página mayor o cambiar el endpoint.

## 4. Iconos, miniaturas y textos

Estado: parcial. Las suscripciones usan el avatar del canal; los videos usan
`hqdefault`.

La miniatura sale de `thumb` en el item:

```objc
YTSet(item, @"thumb", YTIconURL(avatar));
```

`YTEntry` la escribe en `media:thumbnail`. Para cambiar el texto de una celda,
hay dos opciones:

- Cambiar el modelo (`title`, `author`, `views`, `length`) antes del parser.
- Enganchar `YTVideoTableViewCell` / `YTVideoInfoTableViewCell` y reescribir
  sus labels después de `setVideo:`.

Cuidado: `YTImageLoader` cachea por URL y por `videoID`. Una URL de avatar con
el mismo `videoID` que un thumbnail puede devolver la imagen cacheada.

## 5. Enganchar botones

Estado: hecho para like, favorito, suscripción, playlist y comentario.

Los métodos reales de la app:

- `-[YTAuthenticatedAccountPost setRating:forVideo:]`
- `-[YTAuthenticatedAccountPost addVideoToFavorites:]`
- `-[YTAuthenticatedAccountPost removeVideoFromFavorites:]`
- `-[YTAuthenticatedAccountPost postComment:forVideo:]`
- `-[YTSubscriptionsRequest subscribeToUser:]`
- `-[YTAccountFeedRequest addVideo:toPlaylist:]`

El hook hace la llamada InnerTube y avisa al delegado con el tipo que la app
espera:

```objc
BOOL ok = YTAct(@"like/like", YTLikeBody(vid));
if (ok) YTFinishPost(self, 1);
```

No llamar al original si se hace la acción por InnerTube: se duplicaría.

## 6. Player y formato

Estado: hecho. `YTFetchUpstream` pide `player`, `YTPickStreams` elige el mejor
H.264 compatible y el proxy remuxea.

Para cambiar el formato:

- `YTPickStreams` puntúa por altura y bitrate, descarta fps > 30 y perfiles
  level > 3.1.
- `YTEnsure720` acepta desde 360p; el nombre del archivo es histórico.
- El proxy sirve `Range`; el player necesita 206 para buscar.
- Un MP4 con `moov` al final funciona, pero tarda en arrancar; el remux lo deja
  al principio.

No mandar 720p60 ni 1080p al A4: el decodificador los rechaza.

## 7. Modelo YTVideo

Estado: lectura hecha; escritura solo a través de acciones.

El item que consume `YTEntry` tiene estas claves:

| Clave | Uso |
| --- | --- |
| `id` | video ID de 11 caracteres |
| `title` | título visible |
| `author` | canal |
| `length` | `MM:SS` o segundos |
| `seconds` | duración numérica |
| `views` | contador |
| `thumb` | miniatura opcional |
| `published` | texto de fecha |
| `play` | URL directa si se conoce |

El parser crea `YTVideo` a partir del XML. No escribir ivars de `YTVideo` a
mano: usar el feed. Para modificar un video ya cargado, enganchar
`setVideo:` en la celda o `YTVideoDidChangeNotification`.

## 8. Notificaciones

Estado: parcial. Se usan login, signout y recarga de preferencias.

Notificaciones útiles del framework:

- `YTVideoDataSourceDidChangeNotification`
- `YTVideoDataSourceLoadingStatusDidChangeNotification`
- `YTVideoDataSourceHadErrorNotification`
- `YTVideoDidChangeNotification`
- `YTAccountAuthenticatorDidAuthenticateNotification`
- `YTPlaylistsDidChangeNotification`
- `YTVideoBookmarksDidChangeNotification`
- `YTNetworkBecameReachableNotification`

Para refrescar todas las secciones tras cambiar preferencias:

```objc
CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
    CFSTR("com.sokubit.5tube/reload"), NULL, NULL, true);
```

Las notificaciones del framework se postean en el hilo que hace la petición.
Si tocan UI, saltar a la cola principal.

## 9. Captions

Estado: implementado, opt-in con `captionOverlay`.

La app no pide subtítulos en ningún flujo: su binario no contiene la cadena
`caption`. El framework sí tiene `YTCaptionsRequest` y `YTCaptionTrack`, pero
nadie los usa. El endpoint viejo de lista está muerto:

- `api/timedtext?type=list&v=<id>` devuelve 200 con 0 bytes.
- Las pistas reales están en `player.captions.playerCaptionsTracklistRenderer.captionTracks`.
- Cada pista trae un `baseUrl` firmado que devuelve `<timedtext format="3">`.

El tweak:

1. `YTCaptionTracks` pide el `player` y cachea `lang`, `kind`, `name` y `url`.
2. `YTCaptionFeed` responde a la ruta `captions` con un feed de pistas.
3. El proxy `/<id>.<lang>[.asr].srt` descarga el `baseUrl` y convierte el XML a SRT.
4. `YTCaptionPrepare` baja el track al reproducir y `YTCaptionTick` pinta el cue
   activo en un label sobre el player, con un botón CC.

Riesgo: el feed de captions puede tumbar el parser de la app si el formato no
coincide. Por eso `captionOverlay` va apagado por defecto.

## Resumen

| Capacidad | Estado |
| --- | --- |
| Feeds GData | hecho |
| Sección nueva | hecho, opt-in |
| Filtros y paginación | hecho |
| Iconos y textos | parcial |
| Botones | hecho |
| Player y formato | hecho |
| Modelo YTVideo | lectura y acciones |
| Notificaciones | hecho |
| Captions | opt-in |
