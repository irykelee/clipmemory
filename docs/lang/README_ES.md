# ClipMemory (Español)

**Gestor local de historial del portapapeles**

[English](./README_EN.md) · [简体中文](../README.md) · [Español](./README_ES.md) · [Português](./README_PT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md)

---

## Funciones

- 📋 Historial del portapapeles (texto/imágenes/enlaces)
- ⭐ Fija fragmentos importantes
- 💾 Imágenes almacenadas como archivos (sin límite)
- 🔍 Búsqueda rápida
- 🔒 Protección de información sensible (cifrado + limpieza automática)
- ⌨️ Atajo global `⌘⌃V` para abrir
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
| Abrir ventana | `⌘⇧V` (atajo global) |
| Navegar | `↑` / `↓` para navegar |
| Copiar | `Enter` o clic único copia y cierra |
| Cerrar | `Esc` |
| Buscar | Escribir para filtrar en tiempo real |
| Fijar/Desfijar | Doble clic para alternar estado |
| Eliminar | Clic en 🗑 o menú contextual |

## Requisitos

- macOS 13.0 (Ventura) o superior

## Instalación

```bash
brew install irykelee/clipmemory/clipmemory
```

## Desarrollo

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

## Contacto

- GitHub: https://github.com/irykelee/clipmemory
