# ClipMemory v2

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
- 25+ reglas de detección automática de datos sensibles (contraseñas / claves API / números de identificación etc.)
- Pausa automática cuando el gestor de contraseñas está en primer plano, sin copiar desde la App
- Contenido nunca guardado en texto plano si falla el cifrado

---

## Lista de funciones

- 📋 Historial del portapapeles (texto / imágenes / enlaces)
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

---

## Guía de uso

| Acción | Cómo |
|--------|------|
| Abrir Quick Bar | Clic en 📋 de barra menú / `Cmd+Ctrl+V` |
| Copiar elemento | Clic en elemento / ↑↓ + Enter |
| Abrir ventana completa | Quick Bar → "Abrir portapapeles" |
| Buscar | Escribir para filtrar, coincidencias resaltadas |
| Fijar / Desfijar | Clic ⭐ o doble clic en fila |
| Eliminar | Clic 🗑 o menú contextual |
| Vista previa completa / sensible / imagen | Mantener 0.4s, soltar para ocultar |
| Modo de selección múltiple | Clic en casilla |
| Limpiar historial | Barra superior 🗑 (fijados se conservan) |

> 💡 Los elementos fijados nunca se eliminan automáticamente. Copiar el mismo contenido no crea duplicados, solo actualiza la marca de tiempo.

---

## Seguridad

- **AES-256-GCM (v2) + compatibilidad heredada AES-CBC+HMAC-SHA256** — Todo texto e imagen se cifra automáticamente antes de guardar en disco
- **Detección inteligente** — 25+ reglas (palabras clave + expresiones regulares) para contraseñas, claves API, tokens, claves privadas, números de identificación, etc.
- **Borrado automático** — Contenido sensible configurable para borrar tras 1h / 24h / 48h / 7d, o nunca

---

## Ajustes

- Máximo de elementos históricos (50 / 100 / 200 / 500)
- Política de borrado automático sensible (1h / 24h / 48h / 7d / nunca)
- Cambio de idioma (7 idiomas)
- Grabación de atajo global
- Apariencia (Claro / Oscuro / Seguir sistema)
- Apps excluidas (apps personalizadas para excluir del monitoreo)

---

## Requisitos

- macOS 13.0 (Ventura) o superior

---

## Instalación

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
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
