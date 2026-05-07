<details>
<summary><b>🌐 Languages / 语言</b></summary>

| Language | Link |
|----------|------|
| English | [README_EN.md](./README_EN.md) |
| 简体中文 | [README.md](../README.md) |
| 日本語 | [README_JA.md](./README_JA.md) |
| 한국어 | [README_KO.md](./README_KO.md) |
| Español | [README_ES.md](./README_ES.md) |
| Português | [README_PT.md](./README_PT.md) |

---
</details>

---

# ClipMemory (Español)

**Gestor local de historial del portapapeles**

## Funciones

- 📋 Historial del portapapeles (texto/imágenes/enlaces)
- ⭐ Fija fragmentos importantes
- 💾 Imágenes almacenadas como archivos (sin límite)
- 🔍 Búsqueda rápida
- 🔒 Protección de información sensible (cifrado + limpieza automática)
- ⌨️ Atajo global `Cmd+Ctrl+V` para abrir
- 🛡️ Iniciar al arrancar (opcional)
- 🌍 Soporte multilingüe

## Seguridad

- **Cifrado AES-256** — Contenido sensible cifrado con AES-256
- **Gestión segura de claves** — Claves almacenadas localmente
- **Detección inteligente** — 25+ patrones de datos sensibles
- **Limpieza automática** — Tiempo configurable

## Uso

| Acción | Cómo |
|--------|------|
| Abrir ventana | `⌘⇧V` |
| Navegar | `↑` / `↓` |
| Copiar | `Enter` |
| Cerrar | `Esc` |

## Requisitos

- macOS 13.0 (Ventura) o superior

## Instalación

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

## Desarrollo

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

## Contacto

- GitHub: https://github.com/irykelee/clipmemory
