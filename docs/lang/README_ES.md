# ClipMemory v2

**Gestor de portapapeles de nueva generación para macOS — Mejor interfaz, acciones más rápidas, más funciones**

[English](./README_EN.md) · [简体中文](./README_ZH-HANS.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## Mejoras respecto a v1

| Aspecto | v1 | v2 |
|---------|----|----|
| **Interacción** | Clic menú → menú → ventana (3 pasos) | Clic menú → Quick Bar emergente (1 paso) |
| **Ventana principal** | Ancho fijo, sin barra lateral | **Barra lateral fija**: Todo / Texto / Imagen / Enlace / Fijado / Ajustes |
| **Filtro de tipo** | Botones horizontales | Lista vertical en barra lateral con conteo de elementos |
| **Agrupación por tiempo** | Ninguna | Hoy / Ayer / Esta semana / Este mes / Anterior, plegable |
| **Atajo global** | Solo Cmd+Ctrl+V | Personalizable (grabar desde Ajustes) |
| **Quick Bar** | Ninguna | Popover con 8 elementos recientes, buscar + copiar + abrir ventana |
| **Resalte de búsqueda** | Resalte sobre texto | Coincidencia precisa, sin texto corrupto |
| **Vista previa larga** | Ninguna | Texto → completo, sensible → revelar, imagen → ampliar (0.4s) |
| **Disposición iconos** | Casilla + icono tipo + estrella + contenido | Casilla + contenido + estrella + eliminar, más limpio |
| **Estilo ventana** | Ventana estándar | Efecto vidrio, más moderno |
| **Semáforos** | En barra de título | Barra título oculta, área de barra herramientas unificada (macOS 26 Liquid Glass) |
| **Icono Dock** | Siempre oculto | Aparece al abrir ventana, se oculta al cerrar |
| **Resalte hover** | Ninguno | Resalte automático al pasar el ratón |
| **Escala fuente** | Ninguna | Pequeño / Mediano / Grande en Ajustes, toda la UI |
| **Inicio con sesión** | Ninguno (solo menú) | Activar en Ajustes |
| **Página ajustes** | Formulario básico | Página independiente en barra lateral, agrupada y optimizada |

---

## Nuevas funciones

### Quick Bar (popover de menú)
Clic en icono de menú → NSPopover con 8 elementos recientes → clic para copiar / buscar / abrir ventana completa

### Pulsación larga (0.4s)
| Tipo contenido | Vista predeterminada | Tras pulsación larga |
|---------------|---------------------|---------------------|
| Texto normal | Primeros 200 caracteres, 3 líneas | Contenido completo (sin límite) |
| Contenido sensible | Enmascarado `ab••••••yz` | Texto revelado + resalte búsqueda |
| Imagen | Miniatura 80px | Ampliada a 300px |

### Agrupación por tiempo
Lista del portapapeles agrupada automáticamente por fecha: Hoy / Ayer / Esta semana / Este mes / Anterior, secciones plegables.

### Escalado de fuente
Ajustes → Tamaño fuente → Pequeño / Mediano / Grande, escala todo el texto de la interfaz.

### Atajo personalizable
Grabe un nuevo atajo global desde Ajustes para reemplazar el predeterminado `Cmd+Ctrl+V`.

### Sistema de temas
Ajustes permite cambiar el Efecto de ventana (Sólido / Esmerilado / Ultra) y la Apariencia (Claro / Oscuro / Seguir sistema).

---

## Características

- 📋 Historial del portapapeles (texto / imágenes / enlaces)
- ⭐ Fijar elementos importantes, no se eliminan automáticamente
- 💾 Imágenes almacenadas como archivos cifrados, supera límite de 10MB
- 🔍 Búsqueda en tiempo real, resalte preciso en todos los idiomas (incl. chino, japonés, coreano)
- ✅ Retroalimentación visual verde al copiar
- ☑️ Selección múltiple para fijar / eliminar en lote
- 🔒 Detección automática de información sensible (25+ reglas) + cifrado AES-256 + HMAC
- 🔐 Pausa automática cuando el gestor de contraseñas está en primer plano, exclusión de apps personalizada
- ⚡ Deduplicación inteligente — contenido igual actualiza marca de tiempo sin duplicar
- 🔄 Prevención de bucle de copia — salta la captura al copiar desde la app
- 🔒 Seguridad primero: contenido descartado si falla el cifrado, nunca se guarda como texto plano
- 🧹 Limpieza de huérfanos — elimina imágenes no referenciadas al iniciar
- ⚙️ Detección de conflicto de atajo en el primer inicio
- ⌨️ Atajo global `Cmd+Ctrl+V`
- 🌍 7 idiomas (简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português)
- 📎 Ajustes → Acerca de → Enviar comentarios → GitHub Issues

---

## Guía de uso

| Acción | Cómo |
|--------|------|
| Abrir Quick Bar | Clic en 📋 de barra menú / `Cmd+Ctrl+V` |
| Copiar desde Quick Bar | Clic en elemento / ↑↓ + Enter |
| Abrir ventana completa | Quick Bar → "Abrir portapapeles" |
| Buscar | Escribe para filtrar, coincidencias resaltadas |
| Fijar / Desfijar | Clic ⭐, doble clic fila, o menú contextual |
| Eliminar | Clic 🗑 o menú contextual |
| Ver contenido sensible | Mantener 0.4s para mostrar, soltar para ocultar |
| Ampliar imagen | Mantener 0.4s para ampliar, soltar para reducir |
| Ver texto completo | Mantener 0.4s en elemento de texto |
| Selección múltiple | Clic en casilla |
| Operaciones lote | Seleccionar múltiples → fijar / eliminar lote |
| Cerrar ventana | `Esc` |
| Limpiar historial | 🗑 barra superior (fijados se conservan) |

> 💡 Los elementos fijados nunca se eliminan automáticamente. Copiar el mismo contenido no crea duplicados, solo actualiza la marca de tiempo.

---

## Seguridad

- **Cifrado AES-256 + HMAC-SHA256** — Todo texto e imagen se cifra automáticamente antes de guardar en disco
- **Detección inteligente** — 25+ reglas (palabras clave + expresiones regulares) para contraseñas, API keys, tokens, claves privadas, números ID, etc.
- **Borrado automático** — Contenido sensible configurable para borrar tras 1h / 24h / 48h / 7d, o nunca

---

## Ajustes

- Máximo de elementos históricos (50 / 100 / 200 / 500)
- Política de borrado automático sensible (1h / 24h / 48h / 7d / nunca)
- Cambio de idioma (7 idiomas)
- Grabación de atajo global
- Tamaño de fuente (Pequeño / Mediano / Grande)
- Efecto de ventana (Sólido / Esmerilado / Ultra)
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
