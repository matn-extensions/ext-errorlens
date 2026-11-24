module matn.editor.errorlens;

import std.algorithm : canFind, min, max, endsWith;
import std.conv : to;
import std.string : strip, startsWith, indexOf;
import std.path : extension;

import matn.ui.grid.cell : Color, CellStyle, CellAttr;
import matn.ui.grid.grid : GlyphGrid;
import matn.extension.base;

/// Diagnostic severity level
enum DiagnosticSeverity
{
    error,
    warning,
    info
}

/// A line diagnostic annotation
struct LineDiagnostic
{
    int row;
    DiagnosticSeverity severity;
    string message;
    string code = "";
    int col = 0;
    string source = "";
}

/// ErrorLens Extension: Inline diagnostic error and warning annotations at line ends
class ErrorLensExtension : Extension
{
    private LineDiagnostic[int] diagnostics; // row -> LineDiagnostic
    private LineDiagnostic[][string] fileDiagnostics; // normalized filePath -> LineDiagnostic[]

    void delegate() onDiagnosticsChanged;

    this()
    {
        super(ExtensionManifest(
            "matn.errorlens",
            "ErrorLens Diagnostics",
            "1.0.0",
            "Matn Core",
            "Inline compiler & linter diagnostic pills at line ends with severity badges",
            true
        ));
        this._enabled = true;
    }

    override protected void onActivate()
    {
        if (_context)
        {
            _context.registerSetting("EDITOR", "ErrorLens", "Inline line-end diagnostics and error badges", {
                _enabled = !_enabled;
            });
        }
    }

    /**
     * Clears all active diagnostic annotations from the buffer.
     * Called before a new AST syntax pass or linter run.
     */
    void clearDiagnostics()
    {
        diagnostics.clear();
    }

    void setDiagnostic(int row, DiagnosticSeverity severity, string message, string code = "", int col = 0, string source = "")
    {
        diagnostics[row] = LineDiagnostic(row, severity, message, code, col, source);
    }

    void setFileDiagnostics(string filePath, LineDiagnostic[] diags)
    {
        import std.path : buildNormalizedPath;
        fileDiagnostics[buildNormalizedPath(filePath)] = diags;
        if (onDiagnosticsChanged !is null)
            onDiagnosticsChanged();
    }

    void clearFileDiagnostics(string filePath)
    {
        import std.path : buildNormalizedPath;
        fileDiagnostics.remove(buildNormalizedPath(filePath));
        if (onDiagnosticsChanged !is null)
            onDiagnosticsChanged();
    }

    void clearAllFileDiagnostics()
    {
        fileDiagnostics.clear();
        diagnostics.clear();
        if (onDiagnosticsChanged !is null)
            onDiagnosticsChanged();
    }

    bool hasDiagnostic(int row) const
    {
        return _enabled && (row in diagnostics) !is null;
    }

    LineDiagnostic getDiagnostic(int row) const
    {
        if (auto p = row in diagnostics)
            return *p;
        return LineDiagnostic(row, DiagnosticSeverity.info, "");
    }

    const(LineDiagnostic[][string]) getFileDiagnostics() const
    {
        return fileDiagnostics;
    }

    const(LineDiagnostic[int]) getBufferDiagnostics() const
    {
        return diagnostics;
    }

    int getErrorCount() const
    {
        int count = 0;
        foreach (diags; fileDiagnostics)
        {
            foreach (d; diags)
            {
                if (d.severity == DiagnosticSeverity.error)
                    count++;
            }
        }
        return count;
    }

    int getWarningCount() const
    {
        int count = 0;
        foreach (diags; fileDiagnostics)
        {
            foreach (d; diags)
            {
                if (d.severity == DiagnosticSeverity.warning)
                    count++;
            }
        }
        return count;
    }

    int getInfoCount() const
    {
        int count = 0;
        foreach (diags; fileDiagnostics)
        {
            foreach (d; diags)
            {
                if (d.severity == DiagnosticSeverity.info)
                    count++;
            }
        }
        return count;
    }

    /// Fast heuristic analysis of buffer lines to generate smart diagnostics
    void analyzeBuffer(string filePath, const(dchar[][]) lines)
    {
        if (!_enabled) return;
        diagnostics.clear();

        // 0. Populate real compiler / LSP diagnostics if present for this file
        import std.path : buildNormalizedPath;
        string norm = buildNormalizedPath(filePath);
        if (auto p = norm in fileDiagnostics)
        {
            foreach (d; *p)
            {
                diagnostics[d.row] = d;
            }
        }

        string ext = filePath.extension;
        bool isJson = (ext == ".json");

        foreach (r, line; lines)
        {
            if (line.length == 0) continue;
            if (cast(int) r in diagnostics) continue; // Real LSP compiler diagnostic takes precedence!

            string s = to!string(line).strip;
            if (s.length == 0) continue;

            // 1. TODO / FIXME / NOTE / BUG comments
            if (s.canFind("// TODO") || s.canFind("# TODO") || s.canFind("/* TODO"))
            {
                auto idx = s.indexOf("TODO");
                dstring dmsg = to!dstring(s[idx .. $]);
                if (dmsg.length > 36) dmsg = dmsg[0 .. 36] ~ "..."d;
                setDiagnostic(cast(int) r, DiagnosticSeverity.info, to!string(dmsg));
                continue;
            }
            if (s.canFind("// FIXME") || s.canFind("# FIXME") || s.canFind("// BUG"))
            {
                auto idx = s.canFind("// FIXME") ? s.indexOf("FIXME") : s.indexOf("BUG");
                dstring dmsg = to!dstring(s[idx .. $]);
                if (dmsg.length > 36) dmsg = dmsg[0 .. 36] ~ "..."d;
                setDiagnostic(cast(int) r, DiagnosticSeverity.warning, to!string(dmsg));
                continue;
            }

            // 2. JSON trailing comma before closing brace/bracket
            if (isJson)
            {
                if (s.endsWith(",") && r + 1 < lines.length)
                {
                    string nextS = to!string(lines[r + 1]).strip;
                    if (nextS.startsWith("}") || nextS.startsWith("]"))
                    {
                        setDiagnostic(cast(int) r, DiagnosticSeverity.warning, "Trailing comma in JSON");
                        continue;
                    }
                }
            }
        }
    }

    /// Render inline diagnostic badge at line end
    void renderDiagnostic(GlyphGrid grid, int screenRow, int docRow, int startCol, int maxCols, Color defaultBg, bool showIcons = true, bool isLight = false)
    {
        if (!_enabled || !hasDiagnostic(docRow) || startCol >= maxCols) return;

        auto diag = getDiagnostic(docRow);
        if (diag.message.length == 0) return;

        dstring icon;
        Color fg;

        switch (diag.severity)
        {
        case DiagnosticSeverity.error:
            icon = showIcons ? "󰅚 "d : "[E] "d;
            fg = isLight ? Color(185, 35, 40, 255) : Color(240, 115, 120, 255);
            break;
        case DiagnosticSeverity.warning:
            icon = showIcons ? "󰀪 "d : "[W] "d;
            fg = isLight ? Color(165, 105, 15, 255) : Color(230, 180, 70, 255);
            break;
        case DiagnosticSeverity.info:
        default:
            icon = showIcons ? "󰌵 "d : "[I] "d;
            fg = isLight ? Color(30, 105, 175, 255) : Color(110, 180, 240, 255);
            break;
        }

        int avail = maxCols - startCol;
        if (avail <= 2) return;

        dstring text = icon ~ to!dstring(diag.message);
        dstring drawText = text;
        if (drawText.length > avail)
        {
            if (avail > 4)
                drawText = drawText[0 .. avail - 3] ~ "..."d;
            else
                drawText = drawText[0 .. avail];
        }

        int len = cast(int) drawText.length;
        grid.fillRect(startCol, screenRow, len, 1, ' ', CellStyle(fg, defaultBg));
        grid.putString(startCol, screenRow, drawText, CellStyle(fg, defaultBg));
    }
}

unittest
{
    auto el = new ErrorLensExtension();
    const(dchar[][]) code = [
        "void foo("d.dup,
        "    int a,"d.dup,
        "    int b"d.dup,
        ");"d.dup,
        "int[] arr = ["d.dup,
        "    1, 2"d.dup,
        "];"d.dup
    ];

    el.analyzeBuffer("test.d", code);

    // Closing parenthesis on line 3 and bracket on line 6 must NOT flag unexpected closing errors
    assert(!el.hasDiagnostic(3), "Multi-line closing parenthesis should not flag error");
    assert(!el.hasDiagnostic(6), "Multi-line closing bracket should not flag error");

    // Test that when a long line exceeds maxCols, renderDiagnostic safely returns without overwriting
    el.setDiagnostic(0, DiagnosticSeverity.error, "syntax error");
    auto testGrid = new GlyphGrid(80, 24);
    testGrid.putString(50, 0, "some_long_code_identifier_here();"d, CellStyle(Color.white, Color.black));

    // startCol past maxCols should not touch the code at column 50-79
    el.renderDiagnostic(testGrid, 0, 0, 85, 80, Color.black, false);
    assert(testGrid.cells[50].ch == 's', "Code text must not be overwritten when line is long");
}
