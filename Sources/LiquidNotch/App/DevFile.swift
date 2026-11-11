/// This source file's path, for development fallbacks (finding the shader, the 3D model, the adapter and the
/// simulator's assets next to the sources). Debug builds only: a release build carries no local path at all.
#if DEBUG
func devFile(_ path: String = #filePath) -> String { path }
#else
func devFile() -> String { "" }
#endif
