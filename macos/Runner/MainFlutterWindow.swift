import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    
    // Configure window to open in full screen
    if let screen = NSScreen.main {
        self.setFrame(screen.visibleFrame, display: true)
    }

    super.awakeFromNib()
  }
}
