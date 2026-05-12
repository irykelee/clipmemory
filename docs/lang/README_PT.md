# ClipMemory v2

**Gerenciador de área de transferência de nova geração para macOS — Melhor interface, ações mais rápidas, mais recursos**

[English](./README_EN.md) · [简体中文](./README_ZH-HANS.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## Melhorias em relação ao v1

| Aspecto | v1 | v2 |
|---------|----|----|
| **Interação** | Clique menu → menu → janela (3 passos) | Clique menu → Quick Bar pop-up (1 passo) |
| **Janela principal** | Largura fixa, sem barra lateral | **Barra lateral fixa**: Todos / Texto / Imagem / Link / Fixados / Configurações |
| **Filtro de tipo** | Botões horizontais | Lista vertical na barra lateral com contagem de itens |
| **Agrupamento por tempo** | Nenhum | Hoje / Ontem / Esta semana / Este mês / Anterior, recolhível |
| **Atalho global** | Apenas Cmd+Ctrl+V | Personalizável (gravar nas Configurações) |
| **Quick Bar** | Nenhuma | Pop-up com 8 itens recentes, pesquisar + copiar + abrir janela |
| **Destaque de pesquisa** | Destaque sobre texto | Correspondência de subcadeia não diferencia maiúsculas/minúsculas, sem caracteres corrompidos |
| **Visualização longa** | Nenhuma | Texto → completo, sensível → revelar, imagem → ampliar (0.4s) |
| **Disposição ícones** | Caixa + ícone tipo + estrela + conteúdo | Caixa + conteúdo + estrela + excluir, mais limpo |
| **Estilo janela** | Janela padrão | Efeito vidro, mais moderno |
| **Botões de janela** | Na barra de título | Barra título oculta, área de barra ferramentas unificada (macOS 26 Liquid Glass) |
| **Ícone Dock** | Sempre oculto | Aparece ao abrir janela, oculta ao fechar |
| **Destaque hover** | Nenhum | Destaque automático ao passar o mouse |
| **Escala fonte** | Nenhuma | Pequeno / Médio / Grande nas Configurações, toda a UI |
| **Iniciar na sessão** | Nenhum (apenas menu) | Ativar nas Configurações |
| **Página configurações** | Formulário básico | Página independente na barra lateral, agrupada e otimizada |

---

## Novos recursos

### Quick Bar (pop-up da barra de menu)
Clique no ícone da barra de menu → NSPopover com 8 itens recentes → clique para copiar / pesquisar / abrir janela completa

### Pressionar e segurar (0.4s)
| Tipo conteúdo | Visualização padrão | Após pressionar e segurar |
|--------------|-------------------|---------------------------|
| Texto normal | Primeiros 200 caracteres, 3 linhas | Conteúdo completo (sem limite) |
| Conteúdo sensível | Mascarado `ab••••••yz` | Texto revelado + destaque pesquisa |
| Imagem | Miniatura 80px | Ampliada para 300px |

### Agrupamento por tempo
Lista da área de transferência agrupada automaticamente por data: Hoje / Ontem / Esta semana / Este mês / Anterior, seções recolhíveis.

### Escala de fonte
Configurações → Tamanho fonte → Pequeno / Médio / Grande, escala todo texto da interface.

### Atalho personalizável
Grave um novo atalho global nas Configurações para substituir o padrão `Cmd+Ctrl+V`.

### Sistema de temas
Configurações permite ajustar o Efeito de janela (Sólido / Fosco / Ultra) e a Aparência (Claro / Escuro / Seguir sistema).

---

## Características

- 📋 Histórico da área de transferência (texto / imagens / links)
- ⭐ Fixar itens importantes, não são removidos automaticamente
- 💾 Imagens armazenadas como arquivos criptografados, supera limite de 10MB
- 🔍 Pesquisa em tempo real com destaque multilíngue (incluindo caracteres CJK)
- ✅ Feedback visual verde ao copiar
- ☑️ Seleção múltipla para fixar / excluir em lote
- 🔒 Detecção automática de informação sensível (25+ regras) + AES-256-GCM (v2) com compatibilidade legacy AES-CBC+HMAC-SHA256
- 🔐 Pausa automática quando o gerenciador de senhas está em primeiro plano, exclusão de apps personalizada
- ⚡ Desduplicação inteligente — mesmo conteúdo atualiza marca de tempo sem duplicar
- 🔄 Prevenção de loop de cópia — pula captura ao copiar da própria app
- 🔒 Segurança em primeiro lugar: conteúdo descartado se criptografia falhar, nunca salvo como texto simples
- 🧹 Limpeza de órfãos — remove imagens não referenciadas ao iniciar
- ⚙️ Detecção de conflito de atalho na primeira inicialização
- ⌨️ Atalho global `Cmd+Ctrl+V`
- 🌍 7 idiomas (简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português)
- 📎 Configurações → Sobre → Enviar feedback → GitHub Issues

---

## Guia de uso

| Ação | Como |
|------|------|
| Abrir Quick Bar | Clique no 📋 da barra de menu / `Cmd+Ctrl+V` |
| Copiar da Quick Bar | Clique no item / ↑↓ + Enter |
| Abrir janela completa | Quick Bar → "Abrir área de transferência" |
| Pesquisar | Digite para filtrar, correspondências destacadas |
| Fixar / Desfixar | Clique ⭐, clique duplo na linha, ou menu contextual |
| Excluir | Clique 🗑 ou menu contextual |
| Ver conteúdo sensível | Segurar 0.4s para mostrar, soltar para ocultar |
| Ampliar imagem | Segurar 0.4s para ampliar, soltar para reduzir |
| Ver texto completo | Segurar 0.4s em item de texto |
| Seleção múltipla | Clique na caixa de seleção |
| Operações em lote | Selecionar múltiplos → fixar / excluir lote |
| Fechar janela | `Esc` |
| Limpar histórico | 🗑 barra superior (fixados são preservados) |

> 💡 Itens fixados nunca são removidos automaticamente. Copiar o mesmo conteúdo não cria duplicatas, apenas atualiza o timestamp.

---

## Segurança

- **AES-256-GCM (v2) com compatibilidade legacy AES-CBC+HMAC-SHA256** — Todo texto e imagem é criptografado automaticamente antes de salvar em disco
- **Detecção inteligente** — 25+ regras (palavras-chave + expressões regulares) para senhas, API keys, tokens, chaves privadas, números ID, etc.
- **Limpeza automática** — Conteúdo sensível configurável para limpar após 1h / 24h / 48h / 7d, ou nunca

---

## Configurações

- Máximo de itens históricos (50 / 100 / 200 / 500)
- Política de limpeza automática sensível (1h / 24h / 48h / 7d / nunca)
- Troca de idioma (7 idiomas)
- Gravação de atalho global
- Tamanho da fonte (Pequeno / Médio / Grande)
- Efeito de janela (Sólido / Fosco / Ultra)
- Aparência (Claro / Escuro / Seguir sistema)
- Apps excluídas (apps personalizadas para excluir do monitoramento)

---

## Requisitos

- macOS 13.0 (Ventura) ou superior

---

## Instalação

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
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

## Contato

- GitHub: https://github.com/irykelee/clipmemory
- Feedback: Configurações → Sobre → Enviar feedback → GitHub Issues
