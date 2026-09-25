/// Ports Geiss's palette curves (main.cpp references curve #6 as "darkish -
/// allows for fire/sun palette"; several curves total). Original palettes were
/// generated procedurally for 8-bit color tables — on the GPU these become
/// either a small 1D gradient texture per curve or an equivalent shader function.
enum PaletteLibrary {
    static let curveCount = 0 // TODO: enumerate ported curves.
}
