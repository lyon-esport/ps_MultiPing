#Requires -Version 5.1
# Builds MultiPing.exe: a small launcher that starts MultiPing.ps1 from the same folder, without a console window.
# Any arguments given to the .exe are passed to the script, e.g.: MultiPing.exe -CsvPath D:\devices.csv

if ($PSVersionTable.PSEdition -eq 'Core') {
    # Only Windows PowerShell (.NET Framework) can compile an .exe with Add-Type.
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

public static class MultiPingLauncher
{
    [STAThread]
    public static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "MultiPing.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("MultiPing.ps1 was not found next to the launcher:\n" + script,
                "PS MultiPing", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) ps = "pwsh.exe";

        StringBuilder cmd = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -File ");
        cmd.Append(Quote(script));
        foreach (string a in args) cmd.Append(' ').Append(Quote(a));

        ProcessStartInfo psi = new ProcessStartInfo(ps, cmd.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Cannot start PowerShell (" + ps + "):\n" + ex.Message,
                "PS MultiPing", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        return 0;
    }

    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }
}
'@

$out = Join-Path $PSScriptRoot 'MultiPing.exe'
Add-Type -TypeDefinition $code -Language CSharp -OutputAssembly $out -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms
Write-Host "Created $out"
