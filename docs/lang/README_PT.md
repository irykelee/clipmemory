[English](../../README.md) · [简体中文](../../README.md) · [Español](./README_ES.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md)

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

## Funções de segurança

- **Criptografia AES-256** — Conteúdo sensível (senhas, chaves de API) criptografado com AES-256
- **Gerenciamento seguro de chaves** — Chaves armazenadas no macOS Keychain
- **Detecção inteligente** — 25+ padrões de dados sensíveis
- **Limpeza automática** — Tempo configurável para limpeza automática

## Uso

| Ação | Como |
|------|------|
| Abrir janela | `⌘⇧V` |
| Navegar | `↑` / `↓` |
| Copiar | `Enter` |
| Fechar | `Esc` |
| Buscar | Digite para filtrar |
| Fixar | ⭐ clique ou menu→「Fixar」 |
| Excluir | 🗑 clique ou menu→「Excluir」 |

## Configurações

- Máximo de itens (50/100/200/500/1000/2000)
- Limpeza automática de sensíveis (1h/24h/48h/7d/Nunca)
- Troca de idioma

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
