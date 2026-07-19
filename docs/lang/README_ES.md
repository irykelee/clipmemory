# ClipMemory v2.5.6

**Gestor de portapapeles de nueva generación para macOS — Un toque para buscar, instantánea para copiar**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

<p align="center">
  <img src="../screenshots/quick-bar-light-es.jpg" alt="Quick Bar emergente (claro)" width="360"><br>
  <em>Quick Bar desde la barra de menús — 8 elementos recientes, búsqueda y copia al instante (claro)</em>
</p>

<p align="center">
  <img src="../screenshots/quick-bar-dark-es.jpg" alt="Quick Bar emergente (oscuro)" width="360"><br>
  <em>Quick Bar desde la barra de menús — 8 elementos recientes, búsqueda y copia al instante (oscuro)</em>
</p>

<p align="center">
  <img src="../screenshots/main-window-light-es.jpg" alt="Ventana principal de ClipMemory (claro)" width="720"><br>
  <em>Ventana principal: barra lateral por tipo × agrupación por tiempo × resaltado de búsqueda (claro)</em>
</p>

<p align="center">
  <img src="../screenshots/main-window-dark-es.jpg" alt="Ventana principal de ClipMemory (oscuro)" width="720"><br>
  <em>Ventana principal: barra lateral por tipo × agrupación por tiempo × resaltado de búsqueda (oscuro)</em>
</p>

---

## v1 → v2 Mejoras principales

| Aspecto | v1 | v2 |
|---------|----|----|
| **Interacción** | Menú → menú → ventana (3 pasos) | Quick Bar emergente (1 paso) |
| **Ventana principal** | Ancho fijo, sin barra lateral | Barra lateral fija, cambia tipo libremente |
| **Atajo global** | Solo Cmd+Ctrl+V | Grabación personalizada soportada |
| **Quick Bar** | Ninguna | 8 elementos recientes, buscar y copiar al instante |
| **Resalte de búsqueda** | Resalte sobre texto | Sin distinción de mayúsculas/minúsculas, sin caracteres rotos |
| **Vista previa larga** | Ninguna | 0.4s revela texto completo / sensible / imagen |
| **Agrupación por tiempo** | Ninguna | Hoy / Ayer / Anterior, plegable |
| **Etiquetas** | Ninguna | Crear / eliminar / colores personalizados, filtrado en barra lateral + sugerencias inteligentes |
| **Papelera** | Eliminado para siempre | Papelera recuperable con retención configurable |
| **Actualización automática** | Descargas manuales | Comprobación en segundo plano, instalación y reinicio con un clic |
| **Copia local** | Ninguna | Copias diarias automáticas + exportación / importación cifrada |

---

## 📋 Registro de cambios

### v2.5.6 (2026-07-19) — Clave en el Llavero + vista a tamaño real + endurecimiento

- **🔐 Clave migrada al Llavero** — la clave raíz de cifrado pasa de un archivo en texto plano al Llavero de macOS (solo este dispositivo, sin iCloud); brew uninstall --zap también la elimina
- **🖼 Vista de imagen a tamaño real** — pulsación larga para un panel flotante a resolución nativa; las capturas grandes se recorren con scroll y el texto sigue legible (sustituye al zoom de 300px en la fila)
- **🛡 Arranque endurecido** — la corrupción o el fallo al guardar la clave ya no cierran la app; una alerta clara permite salir, reintentar o restablecer (borra el historial)
- **🌐 Espejo con consentimiento** — si el servidor de GitHub no responde, el espejo de jsDelivr ahora pregunta una vez y recuerda tu elección; un espejo desactualizado se rechaza automáticamente

### v2.5.5 (2026-07-18) — Eliminación por condición + endurecimiento

- **🗑 Eliminar por condición** — nueva opción en el menú 🗑 de la barra: tipo × periodo (p. ej. borrar solo imágenes antiguas y conservar las de hoy); clic derecho en una pestaña de tipo para eliminar todo ese tipo; nuevos botones de borrado en las cabeceras de grupo
- **🏷️ Opciones al eliminar etiquetas** — al eliminar una etiqueta puedes elegir «Eliminar solo etiqueta» o «Eliminar etiqueta y contenido (a la Papelera)»
- **🔧 Importación reforzada** — los nombres de etiquetas se descifran correctamente entre máquinas (sin texto corrupto); corregidos duplicados dentro de un mismo paquete, entradas ilegibles importadas al fallar el descifrado, congelamiento de la UI con paquetes grandes y la limpieza de copias borrando archivos ajenos

### v2.5.0 (2026-07-18) — Copia local + exportar/importar

- **💾 Copias locales automáticas** — el historial del portapapeles (incluidas etiquetas, papelera e imágenes) se respalda a diario al primer inicio en una carpeta local de copias, conservando 7 por defecto (3/7/14/30 configurable): un seguro contra la pérdida de datos
- **📦 Exportar / Importar** — exporta con un clic un paquete .clipmemory cifrado (protegido con contraseña); restaura tras cambiar de Mac o reinstalar. La importación fusiona y elimina duplicados con los datos existentes sin sobrescribirlos
- **⚙️ Nueva sección «Copia de seguridad» en Ajustes** — interruptor de copia automática, cantidad a conservar, Copiar ahora, abrir carpeta, exportar/importar

### v2.4.2 (2026-07-18) — Correcciones de estabilidad + canales duales de actualización

- **🌐 Canales duales de actualización** — cambia automáticamente al espejo jsDelivr cuando GitHub no es accesible; las alertas de actualización traen la app al frente con insignia en el Dock (gentle reminders)
- **💾 Seguridad de datos** — los nuevos elementos del portapapeles se escriben en disco de inmediato; antes podían perderse con kill -9 / apagón dentro de la ventana de 500ms
- **🐛 Correcciones de estabilidad** — eliminado el spam del aviso SwiftUI "Modifying state during view update" (decenas por segundo → 0); se detuvieron los errores -9878 repetidos al iniciar cuando el atajo está ocupado

### v2.4.1 (2026-07-18) — Corrección del feed de actualización

- **🌐 Corregido el "error de actualización"** — el feed appcast se migró de raw.githubusercontent.com (inalcanzable en algunas redes) a un activo de GitHub Release; la comprobación responde al instante. Si v2.4.0 muestra un error, descarga v2.4.1 manualmente una vez; la actualización automática se reanuda después

### v2.4.0 (2026-07-18) — Papelera

- **🗑️ Papelera (Recycle Bin)** — Los elementos eliminados ya no se destruyen de inmediato. Pasan a una Papelera donde permanecen 7 días (configurable en Ajustes), durante los cuales puedes restaurarlos o eliminarlos permanentemente. Vaciar la papelera requiere confirmación; los elementos caducados se limpian automáticamente.
- **✨ Actualización automática (Sparkle 2)** — Comprobación de actualizaciones dentro de la app: diaria en segundo plano y manual desde Ajustes. Los paquetes se verifican con firma EdDSA antes de instalarse con un clic y reiniciar; el Cask de Homebrew declara auto_updates.
- **Seguridad de datos** — Los archivos de imagen se conservan mientras su elemento siga en la papelera; solo se eliminan al borrarlo permanentemente. La limpieza automática (trim/expiración) omite la papelera por completo.
- **Actualizaciones de la interfaz** — Nueva entrada «Papelera» en la barra lateral con contador; el texto de confirmación de eliminación cambia a «Mover a la papelera»; los elementos en papelera muestran su fecha de eliminación.
- **Pruebas** — 12 pruebas nuevas para la Papelera, todas superadas.

### v2.3.0 (2026-07-17) — Sistema de Etiquetas e Integridad de Datos

- **🏷️ Sistema de Etiquetas (Tag System)** — Ciclo de vida completo de etiquetas: crear / eliminar / colores personalizados; sección de etiquetas en barra lateral con filtrado AND entre secciones / OR dentro de sección; sugerencias inteligentes (basado en NLTagger: código / email / credencial / sensible); hoja TagPicker (chips en línea + selector de pulsación larga); diálogo de confirmación de eliminación
- **6 correcciones críticas de integridad de datos** — carrera de hilo saveTimer (UB); escrituras síncronas de FileStorageBackend; flushPendingSaves ahora también flushea etiquetas; reparación de marca de cifrado incorrecta en image items legacy; backfill de contentHash; recuperación de fallo parcial de ImageStorage
- **Mejoras de UI** — Dedupe de ventana de bienvenida; Esc cancela grabación de hotkey (evento devuelto al responder); actualización automática de currentDate al cruzar medianoche; expansión forzada de grupos en modo búsqueda (sincronización de navegación por teclado); corrección de typo en pendingMaxItemsReduction
- **Refactor + rendimiento** — RTF NSCache; caché de bundle L10n; estabilización del estado de WindowManager (@State preservado entre cerrar/reabrir); windowDidMove/Resize con debounce 0.5s; +9 net new tests (241 → 250)

### v2.2.4 (2026-07-16) — Higiene de Lanzamiento

- **Versión sincronizada con la etiqueta de release** — `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` actualizadas a `2.2.4` en `project.yml` y `project.pbxproj` regenerado. Resuelve la lección de v2.2.3 donde se cortó la etiqueta sin incrementar la versión.
- **Corrección de etiqueta en Quick Bar** — Eliminada la etiqueta de atajo engañosa `⌘⌃V` en el elemento "abrir ventana completa" de Quick Bar. El atajo global abre la ventana principal completa; Quick Bar se abre con clic izquierdo en el icono 📋 de la barra de menú.
- **Corrección de documentación sobre atajos** — La fila de `Cmd+Ctrl+V` en 8 README reescrita para aclarar que abre la ventana principal, no Quick Bar.
- **Seguridad del script de empaquetado** — `Scripts/package.sh` ahora lee la versión por defecto de `MARKETING_VERSION` en `project.yml` (con guarda si falla la lectura), evitando el problema de empaquetar un tarball con versión antigua cuando se invoca sin argumento.

### v2.2.1 (2026-05-19) — Corrección de Sensibilidad de Imagen

- **Corrección de sensibilidad de imagen** — Las imágenes ya no se marcan automáticamente por tamaño (umbral de 50KB eliminado), almacenamiento controlado por maxItems y limpieza manual
- **Extracción de componentes** — ContentView dividido en FlowLayout, LogoView, DateFilterButton, AppPickerRow, ClipboardItemRow
- **Utilidades compartidas** — Extraídos FontScaling.swift (sz()) y DateHelpers.swift (formatos de fecha)
- **Manejo de presión de memoria NSCache** — Añadido observador de advertencia de memoria del sistema para borrar caché bajo presión

### v2.2.0 (2026-05-15) — Soporte Rich Text

- **Captura de Portapapeles RTF** — Reconoce y guarda automáticamente contenido Rich Text
- **Renderizado Rich Text** — Conversión NSAttributedString → AttributedString
- **Copiar y Pegar** — Escribe ambos tipos de portapapeles .rtf y .string
- **Pestaña de Barra Lateral** — Nueva categoría "Rich Text" con icono, insignia de contador y filtro de tipo
- **Pantalla Quick Bar** — Icono Rich Text + Vista previa de texto plano
- **Enmascaramiento de Contenido Sensible** — Los elementos Rich Text también soportan enmascaramiento
- **85 Pruebas** — Incluyendo 4 pruebas de ida y vuelta Rich Text
- **Búsqueda Mejorada** — Funcionalidad de búsqueda Rich Text corregida

### v2.1.5 (2026-05-11) — Abstracción de Protocolo y Mejoras UX

- **Abstracción de Protocolo** — Protocolo StorageBackend + Backend de prueba MemoryStorageBackend
- **81 Pruebas** — Infraestructura de pruebas completa
- **Diálogo de Recorte Máximo** — Confirmación cuando el historial excede el límite
- **Marcador de Posición de Imagen** — Marcador elegante en fallo de carga
- **Operaciones de Grupo** — Desfijar/limpiar a nivel de grupo

### v2.1.0 (2026-05-09) — Liquid Glass UI

- Lenguaje de diseño Liquid Glass — Barra lateral NavigationSplitView + Pop-up QuickBar
- Correcciones de navegación de teclado — Manejo de teclas de flecha de desplazamiento y búsqueda

---

## Destacados

### Quick Bar — Un toque

Clic en icono de menú → NSPopover con 8 elementos recientes → clic para copiar / buscar / abrir ventana completa

### Pulsación larga 0.4s — Vista previa ilimitada

| Tipo de contenido | Predeterminado | Tras pulsación larga |
|------------------|---------------|---------------------|
| Texto normal | Primeros 200 caracteres, 3 líneas | Texto completo |
| Contenido sensible | Enmascarado `ab••••••yz` | Texto revelado |
| Imagen | Miniatura 80px | Panel flotante a tamaño nativo (con scroll si excede la pantalla) |

### Seguridad inteligente — Cifrado + Detección

- Cifrado AES-256-GCM (v2), compatible con AES-CBC+HMAC-SHA256 heredado
- 35 reglas de detección automática de datos sensibles (contraseñas / claves API / tokens Slack/Discord/OpenAI / números de identificación etc.)
- Pausa automática cuando el gestor de contraseñas está en primer plano, sin copiar desde la App
- Contenido nunca guardado en texto plano si falla el cifrado

---

## Lista de funciones

- 📋 Historial del portapapeles (texto / imágenes / enlaces /**Rich Text RTF**)
- ⭐ Fijar elementos importantes, no se eliminan automáticamente
- 💾 Imágenes almacenadas cifradas, hasta 50MB por imagen
- 🔍 Búsqueda en tiempo real con resalte multilingüe (incluidos caracteres CJK)
- ⚡ Deduplicación inteligente, contenido idéntico solo actualiza marca de tiempo
- 🔄 Prevención de bucle de copia, salta automáticamente la captura desde la App
- 🧹 Limpieza de huérfanos, elimina imágenes no referenciadas al iniciar
- 🌍 7 idiomas (简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português)
- ☑️ Selección múltiple para fijar / eliminar en lote
- ✅ Retroalimentación visual verde al copiar
- ⚙️ Detección automática de conflicto de atajo en el primer inicio
- ⌨️ Atajo global `Cmd+Ctrl+V`
- 🖥 Iniciar con la sesión (activar en Ajustes)
- 📐 Tamaño de fuente (Pequeño / Mediano / Grande)
- 🎨 Apariencia (Claro / Oscuro / Seguir sistema)
- 🗂️ Filtros de tipo (Todo / Texto / Imagen / Enlace / Rich Text)
- ⌨️ Navegación de teclado (desplazamiento con teclas de flecha, manejo de foco de búsqueda)

---

## Guía de uso

| Acción | Cómo |
|--------|------|
| Abrir Quick Bar | Clic en 📋 de barra menú |
| Copiar elemento | Clic en elemento / ↑↓ + Enter |
| Abrir ventana completa | `Cmd+Ctrl+V` (atajo global) / Quick Bar → "Abrir portapapeles" |
| Buscar | Escribir para filtrar, coincidencias resaltadas |
| Fijar / Desfijar | Clic ⭐ o doble clic en fila |
| Eliminar | Clic 🗑 o menú contextual |
| Vista previa completa / sensible / imagen | Mantener 0.4s, soltar para ocultar |
| Modo de selección múltiple | Clic en casilla |
| Limpiar historial | Barra superior 🗑 (fijados se conservan) |
| Eliminar por condición | Barra superior 🗑 → «Eliminar por condición» (tipo × periodo); clic derecho en la pestaña de tipo para eliminar todo ese tipo |
| Cambiar filtro de tipo | Clic en "Texto/Imagen/Enlace/Rich Text" en barra lateral |

> 💡 Los elementos fijados nunca se eliminan automáticamente. Copiar el mismo contenido no crea duplicados, solo actualiza la marca de tiempo.

---

## Seguridad

- **AES-256-GCM (v2) + compatibilidad heredada AES-CBC+HMAC-SHA256** — Todo texto e imagen se cifra automáticamente antes de guardar en disco
- **Detección inteligente** — 35 reglas (palabras clave + expresiones regulares) para contraseñas, claves API, tokens Slack/Discord/OpenAI, claves privadas, números de identificación, etc.
- **Borrado automático** — Contenido sensible configurable para borrar tras 1h / 24h / 48h / 7d, o nunca

---

## Ajustes

- Máximo de elementos históricos (50 / 100 / 200 / 500)
- Política de borrado automático sensible (1h / 24h / 48h / 7d / nunca)
- Cambio de idioma (7 idiomas)
- Grabación de atajo global
- Apariencia (Claro / Oscuro / Seguir sistema)
- Apps excluidas (apps personalizadas para excluir del monitoreo)
- Alternancia de captura Rich Text
- Tamaño de fuente (Pequeño / Mediano / Grande)
- Iniciar al arrancar
- Retención de la papelera (3 / 7 / 14 / 30 días)
- Copia de seguridad (diaria automática / cantidad / exportar / importar)
- Actualizaciones (comprobación automática / comprobar ahora)

---

## Requisitos

- macOS 13.0 (Ventura) o superior

---

## Migración de datos

El historial (incluida la clave de cifrado) se almacena en `~/Library/Application Support/ClipMemory/`.
La forma recomendada de migrar es Ajustes → Copia de seguridad → Exportar copia, que crea un paquete .clipmemory cifrado listo para importar en el nuevo Mac; copiar este directorio manualmente también funciona.
Antes de eliminar la app, haz clic en el botón 🗑 de la barra de herramientas superior para borrar el historial.

---

## Instalación

```bash
brew tap irykelee/clipmemory
brew trust irykelee/clipmemory
brew install --cask clipmemory
```

Tras instalar, la App está en `/Applications/ClipMemory.app`. Busque el icono 📋 en la **barra de menú** (esquina superior derecha) para empezar.

O descargue `.tar.gz` desde [GitHub Releases](https://github.com/irykelee/clipmemory/releases) y extraiga manualmente en `/Applications/`.

> **Si macOS bloquea el primer inicio con "Apple no puede verificar…"**: es el aviso habitual para apps sin notarización, no un virus. ① Clic derecho en la app → **Abrir** → **Abrir** de nuevo; o ② Ajustes del Sistema → Privacidad y seguridad → **Abrir de todos modos**. Solo la primera vez. (Quienes instalan con `brew install` no verán este aviso.)

---

## Desarrollo

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

---

## Contacto

- GitHub: https://github.com/irykelee/clipmemory
- Comentarios: Ajustes → Acerca de → Enviar comentarios → GitHub Issues
