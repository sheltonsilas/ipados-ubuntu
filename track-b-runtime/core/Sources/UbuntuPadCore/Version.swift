/// Versions and phase information reported in diagnostics.
///
/// Deliberately **not** named `UbuntuPadCore`: a type sharing the module's name makes
/// `UbuntuPadCore.version` ambiguous at every use site.
public enum BuildInfo {
    public static let version = "0.1.0"
    public static let phase = "Phase 0 (foundation): ELF header parsing, syscall table, diagnostics"
}
