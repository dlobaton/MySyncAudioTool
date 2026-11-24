# Al Unísono

App local para dos iPhone con iOS 16 o posterior, pensada para un iPhone X actualizado a iOS 16 y un iPhone 17 Pro. Usa Bluetooth LE para intercambiar órdenes y medir la diferencia entre relojes. No usa Wi‑Fi ni transmite los MP3: cada iPhone reproduce su propia copia por el altavoz integrado.

## Instalar sin App Store

1. En un Mac con un Xcode compatible con el iOS instalado en el iPhone 17 Pro, instala XcodeGen (`brew install xcodegen` si usas Homebrew).
2. Copia tus MP3 directamente a `songs/` con nombres como `01-tema.mp3` y `02-tema.mp3`. El orden es alfabético por nombre de archivo completo; usa el mismo número de dígitos en todos los prefijos. También puedes dejar la carpeta vacía y probar solo la sincronización.
3. En la raíz del proyecto, ejecuta `xcodegen generate` y abre `MySyncAudioTool.xcodeproj`. En **Signing & Capabilities**, elige tu equipo de firma (puede ser tu **Personal Team**). Si el identificador `local.mysyncaudiotool.app` no está disponible, cámbialo por uno único en `project.yml` y vuelve a generar.
4. Conecta cada iPhone al Mac, acepta confiar en el equipo, selecciónalo como destino en Xcode y pulsa **Run**. Activa el modo de desarrollador en **Ajustes → Privacidad y seguridad** si iOS lo solicita. Instala la misma compilación en ambos. Con un **Personal Team** gratuito normalmente tendrás que renovar la instalación después de siete días.

## Usar los dos iPhone

1. Activa Bluetooth desde **Ajustes** y abre la app en ambos. Usa los altavoces integrados y mantén la app en primer plano. No hace falta emparejar los iPhone en Ajustes.
2. Pulsa **Sincronizar → Ser anfitrión** en uno y **Sincronizar → Unirme** en el otro. Hazlo con un solo anfitrión activo cerca: el invitado se conecta al primero que encuentra.
3. Coloca los iPhone a una distancia parecida de tu posición. En el anfitrión, pulsa **Reproducir tres pulsos**. Si oyes tres golpes simples, selecciona **Sonaron al unísono** para obtener ✅ en ambos. Si oyes golpes dobles, adelanta o retrasa al invitado en pasos de 2 ms y repite. El asistente muestra ❌ si falla el enlace o si eliges **No consigo alinearlos**.
4. Pulsa **Reproducir lista** en el anfitrión. Ambos preparan y confirman cada pista antes de iniciarla. La siguiente se programa para el final de la anterior cuando hay margen suficiente. Si los dispositivos pierden el enlace o no pueden confirmar un inicio a tiempo, la app detiene la sesión en vez de continuar por separado.

**Límite físico:** la prueba confirma lo que oyes desde tu posición, no una medición entre altavoces. La latencia de salida, la distancia, las diferencias entre relojes y el relleno de algunos MP3 pueden producir pequeños desajustes. La app recalcula el inicio en cada pista; no corrige la deriva a mitad de una canción. Con pistas muy cortas puede haber una pausa para confirmar el siguiente inicio. No se garantiza sincronía a nivel de muestra ni transiciones sin huecos.
