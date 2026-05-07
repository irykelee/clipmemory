[English](../../README.md) · [简体中文](../../README.md) · [Português](./README_PT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md)

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

## Funciones de seguridad

- **Cifrado AES-256** — Contenido sensible (contraseñas, claves API) cifrado con AES-256
- **Gestión segura de claves** — Claves almacenadas en macOS Keychain
- **Detección inteligente** — 25+ patrones de datos sensibles
- **Limpieza automática** — Tiempo configurable para limpieza automática

## Uso

| Acción | Cómo |
|--------|------|
| Abrir ventana | `⌘⇧V` |
| Navegar | `↑` / `↓` |
| Copiar | `Enter` |
| Cerrar | `Esc` |
| Buscar | Escribe para filtrar |
| Fijar | ⭐ clic o menú→「Fijar」 |
| Eliminar | 🗑 clic o menú→「Eliminar」 |

## Ajustes

- Máximo de elementos (50/100/200/500/1000/2000)
- Limpieza automática de sensibles (1h/24h/48h/7d/Nunca)
- Cambio de idioma

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
