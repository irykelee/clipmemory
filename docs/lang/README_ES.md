# ClipMemory v2.3.0

**Gestor de portapapeles de nueva generación para macOS — Un toque para buscar, instantánea para copiar**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

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

---

## 📋 Registro de cambios

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
| Imagen | Miniatura 80px | Ampliada a 300px |

### Seguridad inteligente — Cifrado + Detección

- Cifrado AES-256-GCM (v2), compatible con AES-CBC+HMAC-SHA256 heredado
- 35 reglas de detección automática de datos sensibles (contraseñas / claves API / tokens Slack/Discord/OpenAI / números de identificación etc.)
- Pausa automática cuando el gestor de contraseñas está en primer plano, sin copiar desde la App
- Contenido nunca guardado en texto plano si falla el cifrado

---

## Lista de funciones

- 📋 Historial del portapapeles (texto / imágenes / enlaces /**Rich Text RTF**)
- ⭐ Fijar elementos importantes, no se eliminan automáticamente
- 💾 Imágenes almacenadas como archivos cifrados, supera límite de 10MB
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

---

## Requisitos

- macOS 13.0 (Ventura) o superior

---

## Migración de datos

El historial (incluida la clave de cifrado) se almacena en `~/Library/Application Support/ClipMemory/`.
Haz una copia de seguridad de este directorio antes de reinstalar. Se puede restaurar en el mismo Mac o en uno nuevo para seguir leyendo tu historial.
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
