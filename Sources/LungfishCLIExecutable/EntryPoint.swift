import LungfishCLI

@main
enum EntryPoint {
    static func main() async {
        await LungfishCLIMain.main()
    }
}
