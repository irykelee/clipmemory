const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Header, Footer, PageNumber, BorderStyle, ShadingType, LevelFormat,
  ExternalHyperlink, PageBreak
} = require("docx");

const MONO = "Courier New";
const BODY = "Arial";
const BODY_SIZE = 22; // 11pt
const ACCENT = "2E75B6";

function heading1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: { before: 360, after: 200 },
    children: [new TextRun({ text, font: BODY, size: 32, bold: true, color: ACCENT })],
  });
}

function heading2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: { before: 280, after: 160 },
    children: [new TextRun({ text, font: BODY, size: 26, bold: true, color: "333333" })],
  });
}

function para(text, opts) {
  const runs = [];
  if (typeof text === "string") {
    runs.push(new TextRun({ text, font: BODY, size: BODY_SIZE, ...opts }));
  } else {
    text.forEach(t => runs.push(typeof t === "string" ? new TextRun({ text: t, font: BODY, size: BODY_SIZE, ...opts }) : new TextRun({ font: BODY, size: BODY_SIZE, ...t, ...opts })));
  }
  return new Paragraph({
    spacing: { after: 120 },
    children: runs,
  });
}

function boldPara(text) {
  return para(text, { bold: true });
}

function codeLine(text) {
  return new Paragraph({
    spacing: { after: 0, before: 0 },
    shading: { fill: "F5F5F5", type: ShadingType.CLEAR },
    indent: { left: 360 },
    children: [new TextRun({ text, font: MONO, size: 18 })] },
  );
}

function bullet(text, ref) {
  const runs = typeof text === "string"
    ? [new TextRun({ text, font: BODY, size: BODY_SIZE })]
    : text.map(t => typeof t === "string" ? new TextRun({ text: t, font: BODY, size: BODY_SIZE }) : new TextRun({ font: BODY, size: BODY_SIZE, ...t }));
  return new Paragraph({
    numbering: { reference: ref, level: 0 },
    spacing: { after: 60 },
    children: runs,
  });
}

function linkItem(text, url) {
  return new Paragraph({
    children: [new ExternalHyperlink({
      children: [new TextRun({ text, style: "Hyperlink", font: BODY, size: BODY_SIZE })],
      link: url,
    })],
  });
}

function checkoutItem(text) {
  return bullet([{ text: `[x] ${text}`, font: BODY }], "checklist");
}

function divider() {
  return new Paragraph({
    spacing: { before: 80, after: 80 },
    border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: "DDDDDD", space: 1 } },
    children: [],
  });
}

const doc = new Document({
  styles: {
    default: { document: { run: { font: BODY, size: BODY_SIZE } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 32, bold: true, font: BODY, color: ACCENT },
        paragraph: { spacing: { before: 360, after: 200 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 26, bold: true, font: BODY, color: "333333" },
        paragraph: { spacing: { before: 280, after: 160 }, outlineLevel: 1 } },
    ],
  },
  numbering: {
    config: [
      { reference: "bullets",
        levels: [{ level: 0, format: LevelFormat.BULLET, text: "\u2022", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
      { reference: "checklist",
        levels: [{ level: 0, format: LevelFormat.BULLET, text: "\u2611", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 720, hanging: 360 } } } }] },
    ],
  },
  sections: [
    // ---- Cover / Title ----
    {
      properties: {
        page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } },
      },
      headers: {
        default: new Header({ children: [new Paragraph({
          alignment: AlignmentType.RIGHT,
          children: [new TextRun({ text: "ClipMemory \u00B7 \u526A\u5FC6", font: BODY, size: 18, color: "999999", italics: true })],
        })] }),
      },
      footers: {
        default: new Footer({ children: [new Paragraph({
          alignment: AlignmentType.CENTER,
          children: [new TextRun({ text: "Page ", font: BODY, size: 18, color: "999999" }), new TextRun({ children: [PageNumber.CURRENT], font: BODY, size: 18, color: "999999" })],
        })] }),
      },
      children: [
        new Paragraph({ spacing: { before: 2400 } }),
        new Paragraph({
          alignment: AlignmentType.CENTER,
          spacing: { after: 200 },
          children: [new TextRun({ text: "\u6211\u5199\u4E86\u4E00\u4E2A\u4F1A\u81EA\u52A8\u52A0\u5BC6\u5BC6\u7801\u7684\u526A\u8D34\u677F\u7BA1\u7406\u5668", font: BODY, size: 44, bold: true, color: ACCENT })],
        }),
        new Paragraph({
          alignment: AlignmentType.CENTER,
          spacing: { after: 120 },
          children: [new TextRun({ text: "ClipMemory \u2014 \u4ECE\u5F00\u53D1\u52A8\u673A\u5230\u67B6\u6784\u8BBE\u8BA1\u7684\u5B8C\u6574\u56DE\u987E", font: BODY, size: 26, color: "666666" })],
        }),
        new Paragraph({
          alignment: AlignmentType.CENTER,
          spacing: { before: 400 },
          children: [new TextRun({ text: "v1.2.13  \u00B7  \u514D\u8D39\u5F00\u6E90", font: BODY, size: 22, color: "999999" })],
        }),
        new Paragraph({ children: [new PageBreak()] }),
      ],
    },
    // ---- Body ----
    {
      properties: {
        page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } },
      },
      headers: {
        default: new Header({ children: [new Paragraph({
          alignment: AlignmentType.RIGHT,
          children: [new TextRun({ text: "ClipMemory \u00B7 \u526A\u5FC6", font: BODY, size: 18, color: "999999", italics: true })],
        })] }),
      },
      footers: {
        default: new Footer({ children: [new Paragraph({
          alignment: AlignmentType.CENTER,
          children: [new TextRun({ text: "Page ", font: BODY, size: 18, color: "999999" }), new TextRun({ children: [PageNumber.CURRENT], font: BODY, size: 18, color: "999999" })],
        })] }),
      },
      children: [

        heading1("\u6211\u7684 API key \u5728\u526A\u8D34\u677F\u5386\u53F2\u91CC\u8EBA\u4E86\u4E09\u5929"),

        para("\u4E0D\u662F\u5F00\u73A9\u7B11\u3002"),

        para("\u4E60\u60EF\u6027\u5730\u590D\u5236\u4E00\u4E32 sk- \u5F00\u5934\u7684\u4E1C\u897F\uFF0C\u7C98\u8D34\u5230\u7EC8\u7AEF\u91CC\u8BBE\u73AF\u5883\u53D8\u91CF\u3002\u7136\u540E\u7EE7\u7EED\u5199\u4EE3\u7801\u3002\u8FC7\u4E86\u4E09\u5929\u624D\u53CD\u5E94\u8FC7\u6765\u2014\u2014\u8FD9\u6761 key \u8FD8\u5728\u526A\u8D34\u677F\u5386\u53F2\u91CC\u3002"),

        para("\u6211\u6253\u5F00 ~/Library\uFF0C\u627E\u5230\u90A3\u4E2A\u526A\u8D34\u677F\u7BA1\u7406\u5668\u7684\u6570\u636E\u6587\u4EF6\u3002\u7528\u6587\u672C\u7F16\u8F91\u5668\u6253\u5F00\u3002\u5BC6\u94A5\u3001token\u3001\u8FD8\u6709\u4E0A\u6B21\u7C98\u7684\u6570\u636E\u5E93\u5BC6\u7801\uFF0C\u50BB\u4E4E\u4E4E\u5730\u8EBA\u5728\u4E00\u4E2A plist \u6587\u4EF6\u91CC\uFF0C\u660E\u6587\u3002"),

        para("\u8FD9\u4E0D\u662F\u54EA\u4E2A\u5DE5\u5177\u7684 bug\u3002Maccy\u3001Paste\u3001CopyClip\u3001Flycut\u2026\u2026\u6211\u8BD5\u8FC7\u7684\u6BCF\u4E00\u4E2A\u90FD\u662F\u8FD9\u6837\u3002\u5B83\u4EEC\u90FD\u505A\u4E86\u81EA\u5DF1\u7684\u4E8B\uFF0C\u53EA\u662F\u8C01\u4E5F\u6CA1\u60F3\u8FC7\u201C\u52A0\u5BC6\u201D\u8FD9\u4EF6\u4E8B\u3002"),

        para("\u4E8E\u662F\u6211\u505A\u4E86\u4E00\u4EF6\u6709\u70B9\u610F\u6C14\u7684\u4E8B\uFF1A\u53BB GitHub \u641C \"clipboard manager encrypt\"\u3002"),

        para([{ text: "\u4E00\u4E2A\u7ED3\u679C\u90FD\u6CA1\u6709\u3002", italic: true }]),

        para("\u597D\u5427\u3002\u81EA\u5DF1\u5199\u3002\u8FD9\u5C31\u662F ClipMemory \u7684\u5F00\u59CB\u3002"),

        divider(),

        heading1("\u4E0D\u5F39\u7A97\u3001\u4E0D\u63D0\u95EE\u3001\u4E0D\u8BA9\u7528\u6237\u505A\u9009\u62E9"),

        para("\u8BBE\u8BA1\u76EE\u6807\u5F88\u7B80\u5355\uFF1A\u522B\u4EBA\u7528\u8D77\u6765\u5C31\u662F\u4E00\u4E2A\u666E\u901A\u526A\u8D34\u677F\u7BA1\u7406\u5668\u3002\u4E0D\u5FC5\u5F39\u5BF9\u8BDD\u6846\u95EE\u201C\u8FD9\u6761\u8981\u52A0\u5BC6\u5417\u201D\uFF0C\u4E0D\u5FC5\u624B\u52A8\u70B9\u4EC0\u4E48\u6309\u94AE\u3002\u4E00\u5207\u81EA\u52A8\u3002"),

        para("\u5177\u4F53\u505A\u6CD5\uFF1A"),

        bullet([{ text: "\u6240\u6709\u6587\u672C\u5B58\u76D8\u524D\u5148\u8D70 AES-256-CBC \u52A0\u5BC6", bold: true }, "\uFF0C\u6CA1\u6709\u4F8B\u5916"], "bullets"),
        bullet([{ text: "HMAC-SHA256 \u9632\u7BE1\u6539", bold: true }, "\uFF0C\u4E0D\u662F\u53EA\u52A0\u5BC6\u5C31\u5B8C\u4E8B\uFF0C\u5F97\u8BA9\u5BC6\u6587\u88AB\u52A8\u8FC7\u4E4B\u540E\u80FD\u68C0\u6D4B\u51FA\u6765"], "bullets"),
        bullet([{ text: "\u5BC6\u94A5\u968F\u673A\u751F\u6210", bold: true }, "\uFF0C\u5B58 Application Support \u76EE\u5F55\u4E0B\uFF0C\u6587\u4EF6\u7EA7\u52A0\u5BC6\u4FDD\u62A4"], "bullets"),

        para("\u7528\u6237\u4FA7\u4EC0\u4E48\u90FD\u611F\u89C9\u4E0D\u5230\u3002\u7167\u5E38 Cmd+C\uFF0C\u7167\u5E38\u5728\u754C\u9762\u91CC\u6D4F\u89C8\u5386\u53F2\u3002\u89E3\u5BC6\u53EA\u5728\u6E32\u67D3\u5230\u5C4F\u5E55\u4E0A\u7684\u90A3\u4E00\u77AC\u95F4\u53D1\u751F\u3002\u4E00\u65E6\u5199\u5165\u78C1\u76D8\uFF0C\u5C31\u662F\u5BC6\u6587\u3002"),

        divider(),

        heading1("25+ \u6761\u68C0\u6D4B\u89C4\u5219\uFF0C\u4F46\u4E0D\u662F\u53EA\u9760\u6B63\u5219"),

        para("\u5149\u52A0\u5BC6\u4E0D\u591F\u3002\u5F97\u8BA9\u7528\u6237\u77E5\u9053\u201C\u54E6\u8FD9\u6761\u662F\u654F\u611F\u7684\u201D\uFF0C\u7136\u540E\u5B83\u4F1A\u5728\u8BBE\u5B9A\u65F6\u95F4\u540E\u81EA\u52A8\u6D88\u5931\u3002"),

        para("\u6211\u5199\u4E86\u4E24\u5957\u4E1C\u897F\uFF1A"),

        boldPara("\u7B2C\u4E00\u5957\u53EA\u505A\u5173\u952E\u8BCD\u5339\u914D\uFF0C\u4E0D\u7528\u6B63\u5219\u3002"),
        para("password\u3001api_key\u3001sk-\u3001ghp_\u3001ssh-rsa\u3001token\u3001bearer\u2026\u2026\u5C31\u662F\u8FD9\u4E9B\u660E\u663E\u7684\u4E1C\u897F\u3002\u4E0D\u7528\u6B63\u5219\uFF0C\u76F4\u63A5\u5B57\u7B26\u4E32\u5305\u542B\u5224\u65AD\uFF0C\u5FEB\u5F97\u5F88\u3002"),

        boldPara("\u7B2C\u4E8C\u5957\u7528\u6B63\u5219\uFF0C\u9884\u7F16\u8BD1\u597D\u7684\u3002"),
        para("\u79C1\u94A5\u5934\u90E8\u3001JWT \u7684\u4E09\u6BB5\u7ED3\u6784\u3001AWS Access Key\u3001GitHub token \u3001Stripe key\u3001\u4E2D\u56FD\u8EAB\u4EFD\u8BC1\u53F7\u3001\u94F6\u884C\u5361\u53F7\u3001\u7F8E\u56FD SSN\u3002\u6BCF 0.5 \u79D2\u8F6E\u8BE2\u4E00\u6B21\uFF0C\u4F46\u6B63\u5219\u662F\u542F\u52A8\u65F6\u7F16\u8BD1\u597D\u7684\uFF0C\u8FD0\u884C\u65F6\u6CA1\u5F00\u9500\u3002"),

        para("\u68C0\u6D4B\u5230\u654F\u611F\u9879\u65F6\uFF0C\u754C\u9762\u4E0A\u6807\u6A59\u8272\uFF0C\u9ED8\u8BA4 24 \u5C0F\u65F6\u540E\u81EA\u52A8\u6E05\u9664\u3002\u4F60\u53EF\u4EE5\u6539\u6210 1 \u5C0F\u65F6\u300148 \u5C0F\u65F6\u30017 \u5929\u6216\u6C38\u4E0D\u6E05\u9664\u3002\u6CA1\u6E05\u9664\u4E4B\u524D\u70B9\u4E00\u4E0B\u201C\u67E5\u770B\u201D\u80FD\u770B\u5230\u539F\u6587\u3002"),

        divider(),

        heading1("\u4E94\u4E2A\u670D\u52A1\uFF0C\u6CA1\u6709 MVVM"),

        para("\u6211\u6CA1\u7528 MVVM\u3002\u6709\u4E9B\u4EBA\u89C9\u5F97\u8FD9\u662F\u201C\u4E0D\u89C4\u8303\u201D\uFF0C\u4F46\u6211\u89C9\u5F97\u4E00\u4E2A\u526A\u8D34\u677F\u7BA1\u7406\u5668\u4E0D\u9700\u8981\u90A3\u4E48\u591A\u5C42\u62BD\u8C61\u3002\u4E94\u4E2A\u670D\u52A1\u5404\u53F8\u5176\u804C\uFF0C\u4EE3\u7801\u91CF\u4E5F\u5C0F\uFF0C\u8BFB\u8D77\u6765\u4E0D\u8D39\u8111\u3002"),

        boldPara("ClipboardMonitor"),
        para("\u6BCF 0.5 \u79D2\u770B\u4E00\u6B21 NSPasteboard.changeCount\u3002\u53D8\u4E86\u5C31\u8BFB\u3002\u6587\u672C\u8D70\u68C0\u6D4B\u2192\u52A0\u5BC6\u7BA1\u9053\uFF0C\u56FE\u7247\u5F02\u6B65\u4FDD\u5B58\u3002\u8FD8\u6709\u4E00\u4E2A\u5173\u952E\u4E8B\uFF1A\u81EA\u5DF1\u5199\u5165\u526A\u8D34\u677F\u7684\u5185\u5BB9\u4E0D\u80FD\u518D\u88AB\u81EA\u5DF1\u6355\u83B7\u3002\u5426\u5219\u5C31\u662F\u7ECF\u5178\u7684\u201C\u590D\u5236\u2192\u6355\u83B7\u2192\u91CD\u590D\u6761\u76EE\u2192\u65E0\u9650\u5FAA\u73AF\u201D\u3002recordOwnWrite() \u4E00\u884C\u89E3\u51B3\u3002"),

        boldPara("ClipboardStore"),
        para("ObservableObject \u5355\u4F8B\u3002\u7BA1 items \u548C pinnedItems\u3002\u589E\u5220\u6539\u5168\u5728\u8FD9\u91CC\u3002\u53BB\u91CD\u7528 SHA256\uFF0C\u76F8\u540C\u5185\u5BB9\u4E0D\u91CD\u590D\u8BB0\u5F55\uFF0C\u53EA\u628A\u65E7\u6761\u76EE\u63D0\u5230\u9876\u90E8\u3002contentHash \u9884\u8FC7\u6EE4\u8BA9\u53BB\u91CD\u4E0D\u7528\u6BCF\u6B21\u89E3\u5BC6\u6240\u6709\u6761\u76EE\u3002"),

        boldPara("CryptoService"),
        para("AES-256-CBC + PKCS7 padding + HMAC-SHA256\u3002\u5BC6\u6587\u683C\u5F0F\u662F IV(16\u5B57\u8282) + \u5BC6\u6587 + HMAC(32\u5B57\u8282)\u3002\u89E3\u5BC6\u65F6\u5148\u9A8C HMAC\uFF0C\u4E0D\u8FC7\u5C31\u62D2\u7EDD\u3002\u8FD8\u517C\u5BB9\u4E86\u65E9\u671F\u7248\u672C\u7684\u65E7\u683C\u5F0F\uFF08\u6CA1\u6709 HMAC\u7684\u90A3\u79CD\uFF09\u3002"),

        boldPara("ImageStorage"),
        para("\u56FE\u7247\u4E5F\u52A0\u5BC6\uFF0C\u5B58 Application Support/ClipMemory/Images/ \u4E0B\u3002NSCache \u505A\u5185\u5B58\u7F13\u5B58\uFF0C\u540E\u53F0\u961F\u5217\u505A\u8BFB\u5199\uFF0C\u907F\u514D\u5361\u4E3B\u7EBF\u7A0B\u3002"),

        boldPara("HotKeyManager"),
        para("Carbon Event Manager\uFF0CCmd+Ctrl+V \u5524\u51FA\u7A97\u53E3\u3002Carbon API \u5DF2\u7ECF\u88AB\u82F9\u679C\u6807\u4E3A\u5E9F\u5F03\u4E86\uFF0C\u4F46 macOS 15 \u8FD8\u80FD\u7528\u3002\u6362 CGEvent \u7684\u8BDD\u8981\u5F39\u8F85\u52A9\u529F\u80FD\u6743\u9650\u6846\uFF0C\u6211\u4E0D\u60F3\u8BA9\u7528\u6237\u7B2C\u4E00\u6B21\u5F00\u5C31\u88AB\u8981\u6743\u9650\uFF0C\u5148\u8FD9\u6837\u3002"),

        divider(),

        heading1("\u51E0\u4EF6\u7EA0\u7ED3\u8FC7\u7684\u4E8B"),

        boldPara([{ text: "\u4E0D\u4E0A Mac App Store\uFF1F", bold: true, color: ACCENT }]),
        para("\u8981\u6C99\u76D2\u3002\u867D\u7136\u526A\u8D34\u677F\u548C\u6587\u4EF6\u8BBF\u95EE\u6C99\u76D2\u90FD\u5141\u8BB8\uFF0C\u4F46\u6211\u4E0D\u60F3\u628A\u81EA\u5DF1\u9501\u6B7B\u3002\u7528\u6237\u5927\u90E8\u5206\u662F\u5F00\u53D1\u8005\uFF0Cbrew install \u53EF\u80FD\u6BD4\u53BB App Store \u641C\u66F4\u5FEB\u3002"),

        boldPara([{ text: "AES-256-CBC \u800C\u4E0D\u662F GCM\uFF1F", bold: true, color: ACCENT }]),
        para("Apple \u7684 CommonCrypto \u4E0D\u7ED9\u4F60\u7528 GCM\uFF0C\u5B83\u662F\u79C1\u6709 API\u3002CBC + \u5355\u72EC\u7684 HMAC \u662F\u5B8C\u5168\u5408\u89C4\u7684 Encrypt-then-MAC\uFF0C\u5B89\u5168\u6027\u4E0D\u6BD4 GCM \u5DEE\u3002\u8FD9\u4E2A\u4E0D\u662F\u59A5\u534F\uFF0C\u662F\u82F9\u679C\u6CA1\u7ED9\u9009\u62E9\u3002"),

        boldPara([{ text: "\u5BC6\u94A5\u4E3A\u4EC0\u4E48\u4E0D\u653E Keychain\uFF1F", bold: true, color: ACCENT }]),
        para("\u6211\u60F3\u8FC7\u8FD9\u4E2A\u95EE\u9898\u3002\u5A01\u80C1\u6A21\u578B\u5C31\u4E24\u79CD\uFF1A\u7535\u8111\u4E22\u4E86\u522B\u4EBA\u62FF\u5230\u786C\u76D8\uFF0C\u6216\u8005\u540C\u7528\u6237\u7684\u6076\u610F\u8F6F\u4EF6\u3002\u524D\u8005\u6709 FileVault \u515C\u5E95\u3002\u540E\u8005\u2014\u2014\u5982\u679C\u6076\u610F\u8F6F\u4EF6\u5DF2\u7ECF\u4EE5\u4F60\u7684\u8EAB\u4EFD\u5728\u8FD0\u884C\u4E86\uFF0C\u5B83\u8BFB Keychain \u548C\u8BFB\u6587\u4EF6\u6CA1\u533A\u522B\u3002\u6240\u4EE5\u76F4\u63A5\u5B58\u6587\u4EF6\uFF0C\u66F4\u7B80\u5355\u3002"),

        boldPara([{ text: "SwiftUI \u800C\u4E0D\u662F AppKit\uFF1F", bold: true, color: ACCENT }]),
        para("\u50CF\u7D20\u7EA7\u504F\u597D\u3002\u8FD9\u4E2A\u9879\u76EE UI \u5C31\u662F\u4E00\u4E2A\u641C\u7D22\u6846\u3001\u4E00\u4E2A\u5217\u8868\u3001\u4E00\u4E2A\u8BBE\u7F6E\u9875\u3002SwiftUI \u5B8C\u5168\u591F\u7528\uFF0C\u4E0D\u7528\u5199\u90A3\u4E48\u591A\u5E03\u5C40\u4EE3\u7801\u3002\u552F\u4E00\u7528\u5230 AppKit \u7684\u5730\u65B9\u662F\u952E\u76D8\u4E0A\u4E0B\u5DE6\u53F3\u5BFC\u822A\uFF0C\u7528\u4E86 NSEvent \u7684\u5C40\u90E8\u76D1\u542C\u3002"),

        divider(),

        heading1("\u73B0\u5728\u600E\u4E48\u6837\u4E86"),

        para("\u7ECF\u8FC7\u5FEB 10 \u8F6E\u7684\u4EE3\u7801\u5BA1\u67E5\u548C\u4FEE\u590D\uFF08\u611F\u8C22\u5E2E\u6211 review \u7684\u670B\u53CB\uFF09\uFF0C\u76EE\u524D\u7248\u672C\u5DF2\u7ECF\u6BD4\u8F83\u7A33\u5B9A\u4E86\u3002\u4E0B\u9762\u662F\u5DF2\u7ECF\u505A\u597D\u7684\u90E8\u5206\uFF1A"),

        checkoutItem("\u6587\u672C\u548C\u56FE\u7247\u81EA\u52A8 AES-256 \u52A0\u5BC6\u5B58\u50A8"),
        checkoutItem("25+ \u6761\u654F\u611F\u5185\u5BB9\u68C0\u6D4B\u89C4\u5219\uFF08\u542B\u5173\u952E\u8BCD + \u6B63\u5219\uFF09"),
        checkoutItem("\u641C\u7D22\u9AD8\u4EAE + \u654F\u611F\u9879\u906E\u853D + \u641C\u7D22\u65F6\u5339\u914D\u4E0A\u4E0B\u6587\u5C40\u90E8\u53EF\u89C1"),
        checkoutItem("\u591A\u9009\u6279\u91CF\u56FA\u5B9A / \u5220\u9664"),
        checkoutItem("\u5168\u5C40\u70ED\u952E Cmd+Ctrl+V"),
        checkoutItem("7 \u79CD\u8BED\u8A00\uFF08\u82F1 / \u7B80\u4E2D / \u7E41\u4E2D / \u65E5 / \u97E9 / \u897F / \u8461\uFF09"),
        checkoutItem("\u70B9\u51FB\u590D\u5236\u65F6\u7EFF\u8272\u95EA\u4E00\u4E0B\uFF0C\u77E5\u9053\u6210\u529F\u4E86"),

        para([{ text: "\u5B89\u88C5\u5C31\u4E00\u884C\uFF1A", bold: true }]),
        codeLine("brew install --cask clipmemory"),

        new Paragraph({ spacing: { after: 120 } }),

        linkItem("\u6E90\u7801\u5728 github.com/irykelee/clipmemory", "https://github.com/irykelee/clipmemory"),

        divider(),

        para([{ text: "ClipMemory \u662F\u514D\u8D39\u8F6F\u4EF6\u3002\u4E0D\u6536\u96C6\u6570\u636E\uFF0C\u4E0D\u8054\u7F51\uFF0C\u4E00\u5207\u5728\u672C\u5730\u3002\u6B22\u8FCE\u63D0 issue\uFF0C\u66F4\u6B22\u8FCE PR\u3002", italic: true, color: "999999" }]),
      ],
    },
  ],
});

const OUT = "/Users/iryke/Projects/ClipMemory/docs/ClipMemory-Article.docx";
Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync(OUT, buf);
  console.log("Done:", OUT);
});
