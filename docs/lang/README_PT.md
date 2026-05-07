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

# ClipMemory (Português)

**Gerenciador local de histórico da área de transferência**

## Funções

- 📋 Histórico da área de transferência (texto/imagens/links)
- ⭐ Fixar trechos importantes
- 💾 Imagens armazenadas como arquivos (sem limite)
- 🔍 Busca rápida
- 🔒 Proteção de informações sensíveis (criptografia + limpeza automática)
- ⌨️ Atalho global `Cmd+Ctrl+V` para abrir
- 🛡️ Iniciar ao iniciar sessão (opcional)
- 🌍 Suporte multilíngue

## Segurança

- **Criptografia AES-256** — Conteúdo sensível criptografado com AES-256
- **Gerenciamento seguro de chaves** — Chaves armazenadas localmente
- **Detecção inteligente** — 25+ padrões de dados sensíveis
- **Limpeza automática** — Tempo configurável

## Uso

| Ação | Como |
|------|------|
| Abrir janela | `⌘⇧V` |
| Navegar | `↑` / `↓` |
| Copiar | `Enter` |
| Fechar | `Esc` |

## Requisitos

- macOS 13.0 (Ventura) ou superior

## Instalação

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

## Desenvolvimento

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

## Contato

- GitHub: https://github.com/irykelee/clipmemory
