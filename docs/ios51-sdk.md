# SDK iOS 5.1 y UIKit

Referencia del entorno real del proyecto. No es UIKit moderno: muchas APIs de
iOS 6, 7 y 8 no existen, y el compilador no siempre avisa.

## Toolchain

- SDK: `/home/main/theos/sdks/iPhoneOS5.1.sdk`
- Target: `iphone:clang:5.1:5.1`
- Arquitectura: `armv7`
- Deployment: iOS 5.1.1 en iPhone 3,3 (A4, 512 MB, 640x960)
- Flags del tweak: `-fobjc-arc -Wno-deprecated-declarations`
- Frameworks linkeados: `Foundation`, `UIKit`

El SDK trae 99 headers de UIKit. Los frameworks públicos están completos para
5.1; los privados se declaran a mano o se copian de `theos/vendor/include`.

## Matriz de APIs

| API moderna | iOS 5.1 | Alternativa |
| --- | --- | --- |
| Auto Layout / `NSLayoutConstraint` | no | `autoresizingMask` y frames |
| `UICollectionView` | no | `UITableView` o `UIScrollView` |
| `UIAlertController` | no | `UIAlertView` / `UIActionSheet` |
| `UIActivityViewController` | no | `UIActionSheet`, `Twitter.framework` |
| `UIRefreshControl` | no | botón o gesto propio |
| `UIStackView` | no | frames |
| `UIVisualEffectView` | no | `UIColor` con alpha |
| `NSURLSession` | no | `NSURLConnection` |
| `NSLayoutAnchor` | no | frames |
| `WKWebView` | no | `UIWebView` |
| `UILabel.attributedText` | no | CoreText o varias labels |
| `UIViewPropertyAnimator` | no | `UIView animateWithDuration:` |
| `UIPercentDrivenInteractiveTransition` | no | transición manual |
| `UITableViewRowAction` | no | botones en la celda |
| `UIAlertAction` | no | `UIAlertView` |
| `NSArray.firstObject` | no | `objectAtIndex:0` |
| `array[i]` / `dict[key]` | no fiable | `objectAtIndex:` / `objectForKey:` |
| `NSLineBreakMode` | no | `UILineBreakMode` |
| `NSTextAlignment` | no | `UITextAlignment` |
| `UIFont.systemFontOfSize:weight:` | no | `boldSystemFontOfSize:` |
| `UIImageRenderingModeAlwaysTemplate` | no | imagen normal |

Sí existen y se usan:

- `UIViewController` containment (`addChildViewController:`), desde iOS 5.
- `UIStoryboard` y segues.
- `UIAppearance`.
- `NSJSONSerialization`.
- `NSRegularExpression`.
- `NSCache`.
- `NSOperationQueue`.
- GCD (`dispatch_async`, `dispatch_get_main_queue`).
- ARC con `weak`.
- `objc_setAssociatedObject`.

## UIKit

### Ciclo de vida

- `viewDidLoad`, `viewWillAppear:`, `viewDidAppear:`, `viewWillDisappear:`.
- `viewDidUnload` existe y se llama con avisos de memoria; se usa para soltar
  subvistas y punteros.
- `didReceiveMemoryWarning` es obligatorio en la práctica: 512 MB no perdonan.
- La rotación se controla con `shouldAutorotateToInterfaceOrientation:` y
  `willRotateToInterfaceOrientation:duration:`.
- `UIWindow.rootViewController` existe desde iOS 4.

### Tablas

- `dequeueReusableCellWithIdentifier:` y `prepareForReuse`.
- `UITableViewCellStyleSubtitle` da `textLabel` y `detailTextLabel`.
- No hay `UITableViewRowAction`; las acciones van en botones de la celda o en
  una hoja.
- `reloadData`, `reloadRowsAtIndexPaths:withRowAnimation:`,
  `insertRowsAtIndexPaths:`.
- Las celdas se reciclan: cualquier delegado o descarga asociada a una celda
  debe poder morir con ella.

### Alertas y hojas

- `UIAlertView`: `initWithTitle:message:delegate:cancelButtonTitle:otherButtonTitles:`
  y `show`.
- `UIActionSheet`: `initWithTitle:delegate:cancelButtonTitle:destructiveButtonTitle:otherButtonTitles:`
  y `showInView:`.
- El delegate es `assign`. Si la pantalla muere, la alerta puede mensajear
  memoria liberada. Cerrar la alerta en `dealloc` o al desaparecer.
- No hay `UIAlertController`; los bloques de completion se sustituyen por
  delegate.

### Animación

- `UIView animateWithDuration:animations:completion:`.
- `UIViewAnimationOptions` (`UIViewAnimationOptionCurveEaseInOut`,
  `UIViewAnimationOptionBeginFromCurrentState`).
- `CATransaction` y `CALayer` para lo que UIKit no cubre.
- Las animaciones de `UINavigationController` se enganchan con
  `transitionViewDidComplete:` si se toca la app de YouTube.

### Memoria y ARC

- ARC está activo. `weak` funciona en iOS 5.
- `object_setIvar` no retiene. Para escribir un objeto en un ivar ajeno:
  `objc_setAssociatedObject(obj, ivar, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC)`
  y luego `object_setIvar`.
- `objc_storeStrong` no es público en este SDK.
- `NSZombieEnabled` en el esquema ayuda a cazar delegados muertos.
- Los bloques GCD necesitan `@autoreleasepool` si crean muchos objetos.

## Foundation y red

- `NSURLConnection`:
  - `sendSynchronousRequest:returningResponse:error:` bloquea el hilo. Nunca en
    main si puede tardar.
  - `initWithRequest:delegate:startImmediately:` + `scheduleInRunLoop:` para
    asíncrono.
- `NSURLProtocol` permite interceptar HTTP; cuidado con la recursión: hay que
  marcar la petición interna (`NSURLProtocol setProperty:forKey:inRequest:`).
- `NSJSONSerialization` existe; no hay `JSONDecoder`.
- `NSFileHandle` y `NSFileManager` para archivos.
- `NSNotificationCenter` con bloques existe
  (`addObserverForName:object:queue:usingBlock:`).
- `NSLocale`:
  - `preferredLanguages` existe.
  - `objectForKey:NSLocaleCountryCode` existe.
- No hay `NSURLSession`, ni `NSURLSessionDownloadTask`, ni `NSURLSessionConfiguration`.

TLS: el cliente de iOS 5 no negocia todos los cifrados modernos. Algunos hosts
fallan aunque el certificado sea válido. Para imágenes y avatares, el tweak las
sirve por el proxy local (`127.0.0.1`) para no depender del TLS del cliente.

## Media

- `MPMoviePlayerController` y `MPMediaPlayback`.
- `currentPlaybackTime`, `play`, `pause`, `stop`, `playbackState`, `loadState`.
- `MPMoviePlayerController` no decodifica 1080p ni 60 fps en el A4.
- H.264 Main/High hasta 720p30; AAC-LC.
- `UIMoviePlayerController` es la clase privada que usa YouTube; el tweak la
  engancha para duración y `setMoviePath:`.
- El player pide `Range`; el proxy debe devolver 206.

## Runtime Objective-C y Substrate

- `objc_allocateClassPair`, `class_addMethod`, `objc_registerClassPair` para
  clases creadas en runtime (Trending).
- `class_getInstanceVariable`, `ivar_getOffset`, `object_getIvar`.
- `method_setImplementation` para hooks.
- `MSHookMessageEx` y `MSHookFunction` de MobileSubstrate.
- `objc_setAssociatedObject` para retener delegados o datos ligados a un objeto.
- `NSClassFromString` para clases del framework que no se linkean.

No linkear contra `YouTube.framework`: no está en el SDK. Sus clases se resuelven
en runtime y, si se hereda de ellas, se crean con `objc_allocateClassPair`.

## Frameworks privados útiles

- `YouTube.framework`: red, modelo, parser, auth, player.
- `Preferences.framework`: `PSListController`, `PSSpecifier`, celdas.
- `GraphicsServices.framework`: eventos y `GSEvent`.
- `Celestial.framework`: audio/video.
- `AppSupport.framework`: utilidades del sistema.
- `SpringBoardServices.framework`: servicios de SpringBoard.
- `MobileSubstrate`: hooks.

Los headers de `Preferences` y `SpringBoard` están en
`theos/vendor/include`. Los de YouTube no existen: se declaran a mano.

## Trampas que ya costaron un crash

- `NSArray.firstObject` no existe: `objectAtIndex:0`.
- `CGRectZero` exige linkear CoreGraphics; usar `CGRectMake`.
- `UITextAlignmentCenter`, no `NSTextAlignmentCenter`.
- `object_setIvar` con un array autoreleased deja el ivar colgando.
- `YTSearchRequest` guarda el delegate sin retener; si la pantalla se cierra,
  `didParseData` le habla a memoria reciclada.
- `NSURLConnection sendSynchronousRequest` en main congela la UI.
- Las URLs `//yt3...` no cargan: hay que añadir `https:` o pasar por el proxy.
- `MPMoviePlayerController` no acepta un `play` sin URL válida; el proxy debe
  devolver 200/206 o 404 limpio.

## Checklist para una feature nueva

1. ¿La API existe en el SDK 5.1? Comprobar el header, no la memoria.
2. ¿Necesita un framework extra? Añadirlo a `5Tube_FRAMEWORKS`.
3. ¿Usa delegates `assign`? Retenerlos mientras la petición viva.
4. ¿Toca UI desde un hilo de red? Saltar a main.
5. ¿Se puede probar sin tocar la pantalla? Loguear el estado y usar `curl` local.
6. ¿Cabe en 512 MB? Evitar imágenes grandes y arrays duplicados.
7. ¿Usa TLS moderno? Servir por el proxy local.
8. ¿Es una API de iOS 6+? Buscar la alternativa de la tabla.
