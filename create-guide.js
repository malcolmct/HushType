#!/usr/bin/env node
// create-guide.js — Generate HushType-User-Guide.docx
//
// Usage:  node create-guide.js
//
// Produces a Word document user guide with embedded screenshots (when present)
// and an optional logo image replacing the title text.
//
// Screenshots are loaded from docs/screenshots/ when they exist; otherwise a
// grey placeholder box is rendered with a caption.
//
// Logo: place docs/screenshots/logo.png to replace the "HushType" title text.

const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun,
  Header, Footer, AlignmentType, LevelFormat, HeadingLevel, BorderStyle,
  WidthType, ShadingType, PageNumber, PageBreak,
} = require("docx");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const VERSION = "Version 1.36";
const CREATION_DATE = "9 February 2026";
const OUTPUT_FILE = path.join(__dirname, "HushType-User-Guide.docx");
const SCREENSHOT_DIR = path.join(__dirname, "docs", "screenshots");

// Map each placeholder caption to its expected screenshot filename.
const SCREENSHOT_MAP = {
  "DMG window showing drag-to-install layout": "dmg-install.png",
  "Menu bar showing HushType icon": "menubar-icon.png",
  "HushType permissions window showing permission status": "permission-window.png",
  "macOS microphone permission dialog": "permission-microphone.png",
  "System Settings → Privacy & Security → Accessibility with HushType enabled": "permission-accessibility.png",
  "HushType menu bar dropdown": "menubar-dropdown.png",
  "HushType Settings panel": "settings-panel.png",
};

// ---------------------------------------------------------------------------
// Styling constants
// ---------------------------------------------------------------------------

const BRAND_BLUE = "2E74B5";
const DARK_BLUE = "1F4D78";
const TEXT_COLOR = "2C3E50";
const TIP_BG = "E8F4FD";
const TIP_BORDER = "B8D4E8";
const WARNING_BG = "FFF8E1";
const WARNING_BORDER = "FFE082";
const FONT = "Arial";
const BODY_SIZE = 22;        // 11pt in half-points
const PAGE_WIDTH = 12240;    // US Letter in DXA
const PAGE_HEIGHT = 15840;
const MARGIN = 1440;         // 1 inch
const CONTENT_WIDTH = PAGE_WIDTH - 2 * MARGIN; // 9360 DXA

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Try to load a screenshot from docs/screenshots/. Returns { data, width, height } or null. */
function loadScreenshot(caption) {
  const filename = SCREENSHOT_MAP[caption];
  if (!filename) return null;
  const filepath = path.join(SCREENSHOT_DIR, filename);
  if (!fs.existsSync(filepath)) return null;

  const data = fs.readFileSync(filepath);

  // Read PNG dimensions from IHDR chunk (bytes 16-23)
  let imgWidth = 600, imgHeight = 400;
  if (data.length > 24 && data[1] === 0x50 && data[2] === 0x4E && data[3] === 0x47) {
    imgWidth = data.readUInt32BE(16);
    imgHeight = data.readUInt32BE(20);  // IHDR: width at 16, height at 20 (not 18)
  }

  // Scale to fit content width (max 468pt = 6.5 inches), cap height at 4 inches (288pt)
  const maxWidthPt = 468;
  const maxHeightPt = 288;
  let scale = Math.min(maxWidthPt / imgWidth, maxHeightPt / imgHeight, 1);
  return {
    data,
    width: Math.round(imgWidth * scale),
    height: Math.round(imgHeight * scale),
  };
}

/** Create a screenshot or placeholder paragraph. */
function screenshotBlock(caption) {
  const img = loadScreenshot(caption);
  if (img) {
    return [
      new Paragraph({
        spacing: { before: 120, after: 40 },
        alignment: AlignmentType.CENTER,
        children: [
          new ImageRun({
            type: "png",
            data: img.data,
            transformation: { width: img.width, height: img.height },
            altText: { title: caption, description: caption, name: caption },
          }),
        ],
      }),
      new Paragraph({
        spacing: { after: 200 },
        alignment: AlignmentType.CENTER,
        children: [new TextRun({ text: caption, italics: true, size: 18, color: "888888", font: FONT })],
      }),
    ];
  }

  // Placeholder box
  return [
    new Paragraph({
      spacing: { before: 120, after: 200 },
      alignment: AlignmentType.CENTER,
      children: [
        new TextRun({
          text: `[ Screenshot: ${caption} ]`,
          italics: true,
          size: 20,
          color: "888888",
          font: FONT,
        }),
      ],
      border: {
        top: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC", space: 8 },
        bottom: { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC", space: 8 },
      },
    }),
  ];
}

/** Create a tip/info box. */
function tipBox(text, type = "tip") {
  const bgColor = type === "warning" ? WARNING_BG : TIP_BG;
  const borderColor = type === "warning" ? WARNING_BORDER : TIP_BORDER;
  const border = { style: BorderStyle.SINGLE, size: 1, color: borderColor };
  const borders = { top: border, bottom: border, left: border, right: border };
  return new Table({
    width: { size: CONTENT_WIDTH, type: WidthType.DXA },
    columnWidths: [CONTENT_WIDTH],
    rows: [
      new TableRow({
        children: [
          new TableCell({
            borders,
            width: { size: CONTENT_WIDTH, type: WidthType.DXA },
            shading: { fill: bgColor, type: ShadingType.CLEAR },
            margins: { top: 100, bottom: 100, left: 160, right: 160 },
            children: [
              new Paragraph({
                children: [new TextRun({ text, size: BODY_SIZE, color: TEXT_COLOR, font: FONT })],
              }),
            ],
          }),
        ],
      }),
    ],
  });
}

/** Create a body paragraph. */
function body(text, opts = {}) {
  const children = [];
  // Parse text for **bold** segments
  const parts = text.split(/(\*\*[^*]+\*\*)/g);
  for (const part of parts) {
    if (part.startsWith("**") && part.endsWith("**")) {
      children.push(new TextRun({
        text: part.slice(2, -2),
        bold: true,
        size: BODY_SIZE,
        color: TEXT_COLOR,
        font: FONT,
      }));
    } else {
      children.push(new TextRun({
        text: part,
        size: BODY_SIZE,
        color: TEXT_COLOR,
        font: FONT,
        ...(opts.italics ? { italics: true } : {}),
      }));
    }
  }
  return new Paragraph({
    spacing: { after: opts.spacingAfter ?? 160 },
    alignment: opts.alignment,
    children,
  });
}

/** Heading paragraph. */
function heading(text, level) {
  return new Paragraph({
    heading: level,
    spacing: { before: level === HeadingLevel.HEADING_1 ? 360 : 240, after: 120 },
    children: [new TextRun({ text, font: FONT })],
  });
}

// ---------------------------------------------------------------------------
// Document content
// ---------------------------------------------------------------------------

function buildContent() {
  const children = [];

  // --- Title block ---
  const logoPath = path.join(SCREENSHOT_DIR, "logo.png");
  if (fs.existsSync(logoPath)) {
    const logoData = fs.readFileSync(logoPath);
    let logoW = 400, logoH = 80;
    if (logoData.length > 24 && logoData[1] === 0x50 && logoData[2] === 0x4E && logoData[3] === 0x47) {
      logoW = logoData.readUInt32BE(16);
      logoH = logoData.readUInt32BE(20);  // IHDR: width at 16, height at 20
    }
    // Scale logo to max 450pt wide, 180pt tall
    const scale = Math.min(450 / logoW, 180 / logoH, 1);
    children.push(
      new Paragraph({
        spacing: { after: 80 },
        alignment: AlignmentType.CENTER,
        children: [
          new ImageRun({
            type: "png",
            data: logoData,
            transformation: { width: Math.round(logoW * scale), height: Math.round(logoH * scale) },
            altText: { title: "HushType", description: "HushType logo", name: "logo" },
          }),
        ],
      })
    );
  } else {
    children.push(
      new Paragraph({
        spacing: { after: 80 },
        alignment: AlignmentType.CENTER,
        children: [new TextRun({ text: "HushType", size: 56, color: TEXT_COLOR, font: FONT })],
      })
    );
  }

  children.push(
    body("User Guide", { alignment: AlignmentType.CENTER, spacingAfter: 80 }),
    new Paragraph({
      spacing: { after: 80 },
      alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: "On-device speech-to-text for macOS", italics: true, size: BODY_SIZE, color: "666666", font: FONT })],
    }),
    new Paragraph({
      spacing: { after: 360 },
      alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: VERSION, size: BODY_SIZE, color: "888888", font: FONT })],
    })
  );

  // --- What is HushType? ---
  children.push(heading("What is HushType?", HeadingLevel.HEADING_1));
  children.push(body("HushType is a macOS menu-bar app that turns your speech into text, entirely on your Mac. Hold a trigger key, speak, and your words are typed into whatever application has focus. There is no cloud service involved \u2014 all processing happens locally on your Apple Silicon chip using the Whisper AI model."));
  children.push(body("Because everything runs on-device, HushType works offline, keeps your audio completely private, and responds quickly without network latency."));

  // --- Requirements ---
  children.push(heading("Requirements", HeadingLevel.HEADING_1));
  children.push(
    new Paragraph({
      numbering: { reference: "bullets", level: 0 },
      spacing: { after: 80 },
      children: [
        new TextRun({ text: "macOS 14 (Sonoma) or later", bold: true, size: BODY_SIZE, color: TEXT_COLOR, font: FONT }),
      ],
    }),
    new Paragraph({
      numbering: { reference: "bullets", level: 0 },
      spacing: { after: 80 },
      children: [
        new TextRun({ text: "Apple Silicon Mac", bold: true, size: BODY_SIZE, color: TEXT_COLOR, font: FONT }),
        new TextRun({ text: " \u2014 any Mac with an M1, M2, M3, or M4 chip (Intel Macs are not supported)", size: BODY_SIZE, color: TEXT_COLOR, font: FONT }),
      ],
    }),
    new Paragraph({
      numbering: { reference: "bullets", level: 0 },
      spacing: { after: 160 },
      children: [
        new TextRun({ text: "A working microphone (built-in or external)", size: BODY_SIZE, color: TEXT_COLOR, font: FONT }),
      ],
    })
  );

  // --- Installing HushType ---
  children.push(heading("Installing HushType", HeadingLevel.HEADING_1));
  children.push(body("**1. Download the DMG** from the HushType releases page on GitHub."));
  children.push(body("**2. Open the DMG.** Double-click the downloaded file to mount it."));
  children.push(body("**3. Drag HushType to Applications.** In the window that opens, drag the HushType icon onto the Applications folder alias."));
  children.push(...screenshotBlock("DMG window showing drag-to-install layout"));
  children.push(body('**4. Launch HushType.** Open it from your Applications folder. You may need to right-click and choose "Open" the first time, then confirm in the dialog that appears.'));
  children.push(body("Once all required permissions are granted, HushType will appear as a small icon in your menu bar (near the clock). The icon is hidden until permissions are set up. There is no main window \u2014 the menu bar icon is the app."));
  children.push(...screenshotBlock("Menu bar showing HushType icon"));

  // --- Setting Up Permissions ---
  children.push(heading("Setting Up Permissions", HeadingLevel.HEADING_1));
  children.push(body("HushType needs two macOS permissions to work correctly: **Microphone** and **Accessibility**. A third permission, **App Management**, is recommended for automatic updates but not required. On first launch, HushType displays a **permissions window** that shows the status of each permission at a glance. Each row shows whether the permission is already enabled or still needs to be granted."));
  children.push(...screenshotBlock("HushType permissions window showing permission status"));
  children.push(body("The permissions window stays in the foreground so it is not lost behind other windows. It updates live \u2014 as you grant each required permission, its status changes to a green checkmark. If you close the window before granting both Microphone and Accessibility, HushType will quit, since it cannot function without them. This section explains each permission in detail."));
  children.push(tipBox("Tip: You can always check or change these permissions later in System Settings \u2192 Privacy & Security."));

  // 1. Microphone
  children.push(heading("1. Microphone Access", HeadingLevel.HEADING_2));
  children.push(body("**What it does:** Allows HushType to hear your voice so it can transcribe your speech."));
  children.push(body('**How to enable:** Click the **Enable** button next to Microphone in the permissions window. macOS will show a system dialog \u2014 click **Allow**.'));
  children.push(...screenshotBlock("macOS microphone permission dialog"));
  children.push(body('**If you accidentally denied it:** Open **System Settings \u2192 Privacy & Security \u2192 Microphone**, find HushType in the list, and toggle it on.'));
  children.push(tipBox("Without microphone access, HushType cannot hear you at all. This permission is essential.", "warning"));

  // 2. Accessibility
  children.push(heading("2. Accessibility Access", HeadingLevel.HEADING_2));
  children.push(body("**What it does:** Allows HushType to type the transcribed text into other applications on your behalf. Without this, the app cannot simulate keystrokes or paste text into your active window."));
  children.push(body("**How to enable:** Click the **Enable** button next to Accessibility in the permissions window. This opens System Settings to the correct page. Unlike the microphone dialog, macOS does not grant this permission automatically \u2014 you need to add HushType to the list manually. Here are the steps:"));
  children.push(body("**1. Open System Settings \u2192 Privacy & Security \u2192 Accessibility.**"));
  children.push(body('**2. Click the "+" button at the bottom of the list.**'));
  children.push(body("**3. Navigate to your Applications folder, select HushType, and click Open.**"));
  children.push(body("**4. Make sure the toggle next to HushType is switched on.**"));
  children.push(...screenshotBlock("System Settings \u2192 Privacy & Security \u2192 Accessibility with HushType enabled"));
  children.push(tipBox("Without Accessibility access, HushType will still transcribe your speech, but it can only copy the result to your clipboard. It won\u2019t be able to type the text directly into your applications."));

  // 3. App Management
  children.push(heading("3. App Management (Recommended)", HeadingLevel.HEADING_2));
  children.push(body("**What it does:** Allows HushType to install updates automatically via the built-in Sparkle update system. Without it, updates may be blocked by macOS in some configurations."));
  children.push(body("**Why it\u2019s optional:** If HushType and its updates are signed by the same developer, macOS normally allows the update without this permission. However, edge cases can arise where macOS blocks an update. Granting App Management avoids this."));
  children.push(body('**How to enable:** Click the **Setup\u2026** button next to App Management in the permissions window. This opens System Settings to Privacy & Security and displays guidance in the permissions window. Follow these steps:'));
  children.push(body("**1. In System Settings, select Privacy & Security in the sidebar.**"));
  children.push(body('**2. Scroll down the right-hand panel to find "App Management".**'));
  children.push(body("**3. Click App Management and enable the toggle next to HushType.**"));
  children.push(body("If HushType is not listed under App Management, it will appear automatically the next time an update is available."));
  children.push(tipBox("App Management cannot be detected automatically, so the Setup\u2026 button always remains visible in the permissions window. The counter only tracks the two required permissions (Microphone and Accessibility)."));

  // Re-granting Accessibility
  children.push(heading("Re-granting Accessibility after updates", HeadingLevel.HEADING_3));
  children.push(body("macOS revokes Accessibility permission whenever an app\u2019s code changes \u2014 which happens after every update. This is a macOS security measure, not a bug in HushType. After an update, HushType\u2019s permissions window will appear showing Accessibility as needing attention."));
  children.push(body("If a previous version of HushType is already in the Accessibility list, it must be removed and HushType must be restarted. This is because macOS caches the permission check when the app launches, and a restart is the only way for it to recognise the new entry. The permissions window will display a hint after a few seconds if it detects this situation, along with a **Restart HushType** button that handles the restart automatically. The steps are:"));
  children.push(body('**1. Open System Settings \u2192 Privacy & Security \u2192 Accessibility.**'));
  children.push(body('**2. Select the old HushType entry and click the "\u2212" (minus) button to remove it.**'));
  children.push(body('**3. Click the Restart HushType button in the permissions window.**'));
  children.push(body("**4. HushType will quit and relaunch. In the new permissions window, click Enable next to Accessibility and re-add HushType.**"));
  children.push(body("This only takes a few seconds and is a one-time step after each update. HushType detects when this has happened and will remind you."));

  // Permissions at a glance
  children.push(heading("Permissions at a glance", HeadingLevel.HEADING_2));
  const permBorder = { style: BorderStyle.SINGLE, size: 1, color: "CCCCCC" };
  const permBorders = { top: permBorder, bottom: permBorder, left: permBorder, right: permBorder };
  const permHeaderShading = { fill: "D5E8F0", type: ShadingType.CLEAR };
  const permCellMargins = { top: 80, bottom: 80, left: 120, right: 120 };
  const permColWidths = [2000, 4360, 3000];

  function permCell(text, opts = {}) {
    return new TableCell({
      borders: permBorders,
      width: { size: opts.colWidth || 2000, type: WidthType.DXA },
      shading: opts.header ? permHeaderShading : undefined,
      margins: permCellMargins,
      children: [new Paragraph({
        children: [new TextRun({
          text,
          bold: opts.bold || opts.header,
          size: BODY_SIZE,
          color: TEXT_COLOR,
          font: FONT,
        })],
      })],
    });
  }

  children.push(
    new Table({
      width: { size: CONTENT_WIDTH, type: WidthType.DXA },
      columnWidths: permColWidths,
      rows: [
        new TableRow({
          children: [
            permCell("Permission", { header: true, colWidth: permColWidths[0] }),
            permCell("What happens without it", { header: true, colWidth: permColWidths[1] }),
            permCell("How to grant", { header: true, colWidth: permColWidths[2] }),
          ],
        }),
        new TableRow({
          children: [
            permCell("Microphone", { bold: true, colWidth: permColWidths[0] }),
            permCell("App cannot function at all", { colWidth: permColWidths[1] }),
            permCell("System dialog on first use", { colWidth: permColWidths[2] }),
          ],
        }),
        new TableRow({
          children: [
            permCell("Accessibility", { bold: true, colWidth: permColWidths[0] }),
            permCell("Text copied to clipboard instead of typed", { colWidth: permColWidths[1] }),
            permCell("Manually add in System Settings", { colWidth: permColWidths[2] }),
          ],
        }),
        new TableRow({
          children: [
            permCell("App Management", { bold: true, colWidth: permColWidths[0] }),
            permCell("Updates may be blocked (recommended, not required)", { colWidth: permColWidths[1] }),
            permCell("Setup\u2026 button \u2192 System Settings", { colWidth: permColWidths[2] }),
          ],
        }),
      ],
    })
  );

  // --- Using HushType ---
  children.push(heading("Using HushType", HeadingLevel.HEADING_1));
  children.push(body("Once permissions are set up, HushType is ready to use. The basic workflow is simple:"));
  children.push(body("**1. Click into any text field** \u2014 an email, a document, a chat window, a search bar, anything."));
  children.push(body("**2. Hold the Fn key** (or whichever trigger key you\u2019ve configured in Settings)."));
  children.push(body("**3. Speak clearly.**"));
  children.push(body("**4. Release the key.** Your words will be transcribed and typed at the cursor position."));
  children.push(body("A small floating overlay will appear at the top of your screen while recording, showing audio levels so you know your microphone is picking up your voice."));

  // --- The Menu Bar ---
  children.push(heading("The Menu Bar", HeadingLevel.HEADING_1));
  children.push(body("Clicking the HushType icon in the menu bar opens a dropdown with the following items:"));
  children.push(...screenshotBlock("HushType menu bar dropdown"));
  children.push(body('**Hold [key] to Dictate** \u2014 shows the current status. While idle it displays the trigger key to hold. During recording it changes to "Recording\u2026", and during transcription it changes to "Transcribing\u2026". You can also click this item to start or stop recording manually without using the trigger key.'));
  children.push(body('**Model: [name]** \u2014 shows which Whisper model is currently loaded (for example "small.en"). This is a display-only item; to change the model, use the Settings panel.'));
  children.push(body('**Settings\u2026** \u2014 opens the Settings panel where you can configure all of HushType\u2019s options (see below).'));
  children.push(body('**Check for Updates\u2026** \u2014 manually checks for a new version of HushType. The app also checks automatically in the background.'));
  children.push(body("**About HushType\u2026** \u2014 shows the version number, build number, copyright information, and open-source acknowledgements for WhisperKit and OpenAI Whisper."));
  children.push(body("**Quit HushType** \u2014 exits the application."));

  // --- Settings ---
  children.push(heading("Settings", HeadingLevel.HEADING_1));
  children.push(body('The Settings panel is organised into seven sections. Open it by clicking the HushType menu bar icon and selecting "Settings\u2026".'));
  children.push(...screenshotBlock("HushType Settings panel"));

  // General
  children.push(heading("General", HeadingLevel.HEADING_2));
  children.push(body("**Start HushType at login** \u2014 when enabled, HushType will launch automatically each time you log in to your Mac. This integrates with macOS\u2019s built-in Login Items system (visible in System Settings \u2192 General \u2192 Login Items), so you can also toggle it from there."));

  // Activation
  children.push(heading("Activation", HeadingLevel.HEADING_2));
  children.push(body("**Trigger key** \u2014 the modifier key you hold to start recording. Choose from Fn (the default), Control, or Option. The trigger key must be pressed alone; holding other modifier keys at the same time is ignored to prevent false triggers from keyboard shortcuts. Shift and Command are deliberately excluded because they conflict with too many system and application shortcuts."));

  // Whisper Model
  children.push(heading("Whisper Model", HeadingLevel.HEADING_2));
  children.push(body('**Current** \u2014 displays the name of the Whisper model currently loaded. The default is "small.en", which provides a good balance between speed and accuracy for English.'));
  children.push(body("**Show all models (advanced)** \u2014 tick this checkbox to reveal a dropdown listing every available model, from the fastest (tiny) to the most accurate (large-v3). Smaller models transcribe faster and use less memory; larger models produce better results, especially for non-English languages or difficult audio. If the model you select is not already on your Mac, HushType will download it automatically (a progress window will appear)."));
  children.push(body("Available models, in order from fastest to most accurate: tiny, tiny.en, base, base.en, small, small.en, medium, medium.en, large-v3, and large-v3-turbo. Models ending in \u201C.en\u201D are English-only and slightly more accurate for English speech."));

  // Language
  children.push(heading("Language", HeadingLevel.HEADING_2));
  children.push(body('**Language** \u2014 choose the language you will be speaking. The default is "Auto-detect", which lets Whisper identify the language from the audio. Setting an explicit language can improve accuracy. HushType supports 30 languages including English, Spanish, French, German, Chinese, Japanese, Korean, Arabic, and many more.'));
  children.push(tipBox("If you select a non-English language while using an English-only model (e.g. small.en), HushType will automatically switch to the equivalent multilingual model (e.g. small)."));

  // Text Injection
  children.push(heading("Text Injection", HeadingLevel.HEADING_2));
  children.push(body("This controls how HushType types the transcribed text into your active application. There are two methods:"));
  children.push(body("**Clipboard paste (\u2318V)** \u2014 the default and recommended method. HushType temporarily copies the text to your clipboard, simulates a Cmd+V paste, and then restores whatever was on your clipboard before. This handles all Unicode characters, punctuation, and special characters perfectly."));
  children.push(body("**Simulated keystrokes** \u2014 types each character individually by simulating keyboard events. This can feel more natural in some applications but is limited to the US keyboard layout and may miss certain symbols. Use this if clipboard paste causes issues in a particular application."));

  // Audio Input
  children.push(heading("Audio Input", HeadingLevel.HEADING_2));
  children.push(body('**Input device** \u2014 choose which microphone HushType uses. The default is "System Default", which uses whichever microphone macOS has selected. If you have multiple microphones (for example a built-in mic and a USB headset), you can select a specific one here.'));

  // Display
  children.push(heading("Display", HeadingLevel.HEADING_2));
  children.push(body("**Show recording overlay** \u2014 when enabled, a small floating indicator appears at the top of your screen during recording. It shows audio levels so you can see that your microphone is picking up your voice. The overlay never steals focus from your active application. Disable this if you find it distracting."));
  children.push(body("**Menu bar icon** \u2014 choose between the custom HushType icon (the default) or a standard system microphone icon (SF Symbol). The HushType icon is designed to be easily distinguishable from Apple\u2019s own microphone icons that may appear in the menu bar."));

  // --- Automatic Updates ---
  children.push(heading("Automatic Updates", HeadingLevel.HEADING_1));
  children.push(body("HushType includes a built-in update mechanism powered by Sparkle. The app periodically checks for new versions in the background, and when one is available, it will prompt you to install it. Updates are downloaded and applied automatically \u2014 you just need to confirm when asked. You can also check for updates manually at any time by clicking the menu bar icon and selecting \u201CCheck for Updates\u2026\u201D."));
  children.push(body("All updates are cryptographically signed to ensure they are genuine and have not been tampered with. The update files are hosted on GitHub and verified before installation."));
  children.push(tipBox("For the smoothest update experience, grant the App Management permission as described in the Setting Up Permissions section. This ensures macOS does not block HushType from installing updates."));
  children.push(body("**Remember:** after each update, macOS will require you to re-grant Accessibility permission (see the Setting Up Permissions section). HushType will remind you when this is needed."));

  // --- Troubleshooting ---
  children.push(heading("Troubleshooting", HeadingLevel.HEADING_1));

  children.push(heading("Text goes to clipboard instead of being typed", HeadingLevel.HEADING_2));
  children.push(body("This means Accessibility permission is missing or was revoked after an update. Follow the Accessibility steps above to re-grant it."));

  children.push(heading("No sound is being captured", HeadingLevel.HEADING_2));
  children.push(body("Check that Microphone permission is granted in System Settings \u2192 Privacy & Security \u2192 Microphone. Also check that the correct input device is selected in HushType\u2019s Settings panel."));

  children.push(heading("The app won\u2019t open / shows a security warning", HeadingLevel.HEADING_2));
  children.push(body("Right-click the app in your Applications folder and choose **Open**. macOS may show a warning for apps downloaded outside the App Store. Clicking Open from the right-click menu bypasses Gatekeeper for that specific launch. You only need to do this once."));

  children.push(heading("Updates are failing", HeadingLevel.HEADING_2));
  children.push(body("Make sure you have a working internet connection and try again from the menu bar: click the HushType icon and choose **Check for Updates**. If macOS is blocking the update, grant App Management permission in System Settings \u2192 Privacy & Security \u2192 App Management (see the Setting Up Permissions section). If the update still fails, download the latest version manually from the HushType website and replace the app in your Applications folder."));

  children.push(heading("Transcription is inaccurate or repeats phrases", HeadingLevel.HEADING_2));
  children.push(body('Try switching to a larger Whisper model in Settings (for example, from "small.en" to "medium.en" or "large-v3"). Larger models are significantly more accurate, especially with background noise, accents, or complex vocabulary. If you are speaking a language other than English, make sure the correct language is selected in Settings and that you are using a multilingual model (one without the ".en" suffix).'));

  // --- Footer ---
  children.push(
    new Paragraph({ children: [new PageBreak()] }),
    new Paragraph({
      spacing: { before: 200, after: 40 },
      alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: `Created: ${CREATION_DATE}`, size: 18, color: "888888", font: FONT })],
    }),
    new Paragraph({
      alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: "\u00A9 2026 Malcolm Taylor. All rights reserved.", size: 18, color: "888888", font: FONT })],
    })
  );

  return children;
}

// ---------------------------------------------------------------------------
// Build and write document
// ---------------------------------------------------------------------------

async function main() {
  const doc = new Document({
    styles: {
      default: {
        document: {
          run: { font: FONT, size: BODY_SIZE, color: TEXT_COLOR },
        },
      },
      paragraphStyles: [
        {
          id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: 32, bold: false, font: FONT, color: BRAND_BLUE },
          paragraph: { spacing: { before: 360, after: 120 }, outlineLevel: 0 },
        },
        {
          id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: 26, bold: false, font: FONT, color: BRAND_BLUE },
          paragraph: { spacing: { before: 240, after: 120 }, outlineLevel: 1 },
        },
        {
          id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: 24, bold: false, font: FONT, color: DARK_BLUE },
          paragraph: { spacing: { before: 240, after: 120 }, outlineLevel: 2 },
        },
      ],
    },
    numbering: {
      config: [
        {
          reference: "bullets",
          levels: [{
            level: 0,
            format: LevelFormat.BULLET,
            text: "\u2022",
            alignment: AlignmentType.LEFT,
            style: { paragraph: { indent: { left: 720, hanging: 360 } } },
          }],
        },
      ],
    },
    sections: [{
      properties: {
        page: {
          size: { width: PAGE_WIDTH, height: PAGE_HEIGHT },
          margin: { top: MARGIN, right: MARGIN, bottom: MARGIN, left: MARGIN },
        },
      },
      headers: {
        default: new Header({
          children: [
            new Paragraph({
              alignment: AlignmentType.RIGHT,
              children: [new TextRun({ text: "HushType User Guide", size: 16, color: "AAAAAA", font: FONT })],
            }),
          ],
        }),
      },
      footers: {
        default: new Footer({
          children: [
            new Paragraph({
              alignment: AlignmentType.CENTER,
              children: [
                new TextRun({ text: "Page ", size: 16, color: "AAAAAA", font: FONT }),
                new TextRun({ children: [PageNumber.CURRENT], size: 16, color: "AAAAAA", font: FONT }),
              ],
            }),
          ],
        }),
      },
      children: buildContent(),
    }],
  });

  const buffer = await Packer.toBuffer(doc);
  fs.writeFileSync(OUTPUT_FILE, buffer);
  console.log(`Created: ${OUTPUT_FILE}`);
  console.log(`  ${VERSION}`);
}

main().catch((err) => {
  console.error("Error creating guide:", err);
  process.exit(1);
});
