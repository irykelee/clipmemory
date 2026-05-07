# ClipMemory (Português)

**Gerenciador local de histórico da área de transferência**

[English](./README_EN.md) · [简体中文](../README.md) · [Español](./README_ES.md) · [Português](./README_PT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md)

---

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
| Abrir janela | `⌘⇧V` (atalho global) |
| Navegar | `↑` / `↓` para navegar |
| Copiar | `Enter` ou clique único copia e fecha |
| Fechar | `Esc` |
| Buscar | Digite para filtrar em tempo real |
| Fixar/Desfixar | Clique duplo para alternar |
| Excluir | Clique em 🗑 ou menu contextual |

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
