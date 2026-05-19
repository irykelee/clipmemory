# ClipMemory v2.2.1

**Gestor de área de transferência de nova geração para macOS — Um toque para pesquisar, cópia instantânea**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## v1 → v2 Melhorias principais

| Aspecto | v1 | v2 |
|---------|----|----|
| **Interação** | Menu → menu → janela (3 passos) | Quick Bar popup (1 passo) |
| **Janela principal** | Largura fixa, sem barra lateral | Barra lateral fixa, alterna tipo livremente |
| **Atalho global** | Apenas Cmd+Ctrl+V | Gravação personalizada suportada |
| **Quick Bar** | Nenhuma | 8 itens recentes, pesquisar e copiar instantaneamente |
| **Destaque de pesquisa** | Destaque sobre texto | Não diferencia maiúsculas/minúsculas, sem caracteres corrompidos |
| **Visualização longa** | Nenhuma | 0.4s revela texto completo / sensível / imagem |
| **Agrupamento por tempo** | Nenhum | Hoje / Ontem / Anterior, recolhível |

---

## 📋 Registro de alterações

### v2.2.1 (2026-05-19) — Correção de Sensibilidade de Imagem

- **Correção de sensibilidade de imagem** — Imagens não são mais marcadas automaticamente por tamanho (limite de 50KB removido), armazenamento controlado por maxItems e limpeza manual
- **Extração de componentes** — ContentView dividido em FlowLayout, LogoView, DateFilterButton, AppPickerRow, ClipboardItemRow
- **Utilitários compartilhados** — Extraídos FontScaling.swift (sz()) e DateHelpers.swift (formatadores de data)
- **Tratamento de pressão de memória NSCache** — Adicionado observador de aviso de memória do sistema para limpar cache sob pressão

### v2.2.0 (2026-05-15) — Suporte Rich Text

- **Captura de Área de Transferência RTF** — Reconhece e salva automaticamente conteúdo Rich Text
- **Renderização Rich Text** — Conversão NSAttributedString → AttributedString
- **Copiar e Colar** — Escreve ambos os tipos de área de transferência .rtf e .string
- **Aba da Barra Lateral** — Nova categoria "Rich Text" com ícone, emblema de contagem e filtro de tipo
- **Exibição Quick Bar** — Ícone Rich Text + Visualização de texto simples
- **Mascaramento de Conteúdo Sensível** — Itens Rich Text também suportam mascaramento
- **85 Testes** — Incluindo 4 testes de ida e volta Rich Text
- **Pesquisa Corrigida** — Funcionalidade de pesquisa Rich Text corrigida

### v2.1.5 (2026-05-11) — Abstracción de Protocolo e Melhorias UX

- **Abstração de Protocolo** — Protocolo StorageBackend + Backend de teste MemoryStorageBackend
- **81 Testes** — Infraestrutura de testes completa
- **Diálogo de Corte Máximo** — Confirmação quando o histórico excede o limite
- **Marcador de Posição de Imagem** — Marcador elegante em falha de carregamento
- **Operações de Grupo** — Desafixar/limpar no nível de grupo

### v2.1.0 (2026-05-09) — Liquid Glass UI

- Linguagem de design Liquid Glass — Barra lateral NavigationSplitView + Pop-up QuickBar
- Correções de navegação de teclado — Tratamento de teclas de seta de rolagem e pesquisa

---

## Destaques

### Quick Bar — Um toque

Clique no ícone da barra de menu → NSPopover com 8 itens recentes → clique para copiar / pesquisar / abrir janela completa

### Pressionar e segurar 0.4s — Visualização ilimitada

| Tipo de conteúdo | Padrão | Após pressionar |
|-----------------|--------|-----------------|
| Texto normal | Primeiros 200 caracteres, 3 linhas | Texto completo |
| Conteúdo sensível | Mascarado `ab••••••yz` | Texto revelado |
| Imagem | Miniatura 80px | Ampliada para 300px |

### Segurança inteligente — Criptografia + Deteção

- Criptografia AES-256-GCM (v2), compatível com legacy AES-CBC+HMAC-SHA256
- 26 regras de detecção automática de dados sensíveis (senhas / chaves de API / tokens Slack/Discord/OpenAI / números de identificação etc.)
- Pausa automática quando o gestor de palavras-passe está em primeiro plano, sem copiar da App
- Conteúdo nunca guardado em texto simples se a criptografia falhar

---

## Lista de funções

- 📋 Histórico da área de transferência (texto / imagens / links /**Rich Text RTF**)
- ⭐ Fixar itens importantes, não são removidos automaticamente
- 💾 Imagens armazenadas como arquivos criptografados, supera limite de 10MB
- 🔍 Pesquisa em tempo real com destaque multilíngüe (incluindo caracteres CJK)
- ⚡ Desduplicação inteligente, mesmo conteúdo atualiza marca de tempo sem duplicar
- 🔄 Prevenção de loop de cópia, salta captura ao copiar da própria app
- 🧹 Limpeza de órfãos, remove imagens não referenciadas ao iniciar
- 🌍 7 idiomas (简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português)
- ☑️ Seleção múltipla para fixar / excluir em lote
- ✅ Feedback visual verde ao copiar
- ⚙️ Detecção automática de conflito de atalho na primeira inicialização
- ⌨️ Atalho global `Cmd+Ctrl+V`
- 🖥 Iniciar na sessão (ativar nas Configurações)
- 📐 Tamanho da fonte (Pequeno / Médio / Grande)
- 🎨 Aparência (Claro / Escuro / Seguir sistema)
- 🗂️ Filtros de tipo (Tudo / Texto / Imagem / Link / Rich Text)
- ⌨️ Navegação de teclado (rolagem com teclas de seta, tratamento de foco de pesquisa)

---

## Guia de uso

| Ação | Como |
|------|------|
| Abrir Quick Bar | Clique no 📋 da barra de menu / `Cmd+Ctrl+V` |
| Copiar item | Clique no item / ↑↓ + Enter |
| Abrir janela completa | Quick Bar → "Abrir área de transferência" |
| Pesquisar | Digite para filtrar, correspondências destacadas |
| Fixar / Desfixar | Clique ⭐ ou clique duplo na linha |
| Excluir | Clique 🗑 ou menu contextual |
| Ver completo / sensível / imagem | Segurar 0.4s, soltar para ocultar |
| Modo de seleção múltipla | Clique na caixa de seleção |
| Limpar histórico | Barra superior 🗑 (fixados são preservados) |
| Alternar filtro de tipo | Clique em "Texto/Imagem/Link/Rich Text" na barra lateral |

> 💡 Itens fixados nunca são removidos automaticamente. Copiar o mesmo conteúdo não cria duplicatas, apenas atualiza o timestamp.

---

## Segurança

- **AES-256-GCM (v2) + compatibilidade legacy AES-CBC+HMAC-SHA256** — Todo texto e imagem é criptografado automaticamente antes de salvar em disco
- **Detecção inteligente** — 26 regras (palavras-chave + expressões regulares) para senhas, chaves de API, tokens Slack/Discord/OpenAI, chaves privadas, números de identificação, etc.
- **Limpeza automática** — Conteúdo sensível configurável para limpar após 1h / 24h / 48h / 7d, ou nunca

---

## Configurações

- Máximo de itens históricos (50 / 100 / 200 / 500)
- Política de limpeza automática sensível (1h / 24h / 48h / 7d / nunca)
- Troca de idioma (7 idiomas)
- Gravação de atalho global
- Aparência (Claro / Escuro / Seguir sistema)
- Apps excluídas (apps personalizadas para excluir do monitoramento)
- Alternância de captura Rich Text

---

## Requisitos

- macOS 13.0 (Ventura) ou superior

---

## Migração de dados

O histórico (incluindo a chave de criptografia) é armazenado em `~/Library/Application Support/ClipMemory/`.
Faça backup deste diretório antes de reinstalar — ele pode ser restaurado no mesmo Mac ou em um novo Mac para continuar lendo seu histórico.
Antes de remover o app, clique no botão 🗑 na barra de ferramentas superior para limpar o histórico.

---

## Instalação

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install clipmemory
```

Após instalar, o App está em `/Applications/ClipMemory.app`. Encontre o ícone 📋 na **barra de menu** (canto superior direito) para começar.

Ou baixe `.tar.gz` do [GitHub Releases](https://github.com/irykelee/clipmemory/releases) e extraia manualmente em `/Applications/`.

---

## Desenvolvimento

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

---

## Contacto

- GitHub: https://github.com/irykelee/clipmemory
- Feedback: Configurações → Sobre → Enviar feedback → GitHub Issues
