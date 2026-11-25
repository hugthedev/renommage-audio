import AppKit
import AudioRenamerCore

// Interface macOS. Les fichiers arrivent par « application(_:openFiles:) » lorsqu'ils sont
// déposés sur l'icône dans le Finder ou le Dock. Aucune notification macOS.

func showAlert(title: String, text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

/// Fenêtre de validation : compteurs, tableau AVANT / APRÈS, Valider / Annuler.
/// Fermer la fenêtre n'est jamais une validation.
final class ValidationWindowController: NSObject, NSTableViewDataSource, NSWindowDelegate {
    private let plan: Plan
    private let rows: [[String]]
    private var window: NSWindow!

    init(plan: Plan) {
        self.plan = plan
        self.rows = Report.rows(plan)
        super.init()
        buildWindow()
    }

    private func buildWindow() {
        let width: CGFloat = 900
        let height: CGFloat = 660
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Vérification avant renommage"
        window.isReleasedWhenClosed = false
        window.delegate = self
        guard let content = window.contentView else { return }

        var y = height - 30
        let heading = NSTextField(labelWithString: "Résultat de l'analyse (aucun fichier n'a encore été modifié)")
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        heading.frame = NSRect(x: 20, y: y, width: width - 40, height: 20)
        content.addSubview(heading)
        y -= 22

        for (name, count) in Report.summary(plan) {
            let line = NSTextField(labelWithString: "\(name) : \(count)")
            line.frame = NSRect(x: 20, y: y, width: width - 40, height: 16)
            content.addSubview(line)
            y -= 18
        }

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: width - 40, height: y - 80))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let table = NSTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = true
        for (id, title, columnWidth) in [("0", "Élément", 320.0), ("1", "AVANT", 270.0), ("2", "APRÈS", 270.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(columnWidth)
            table.addTableColumn(column)
        }
        table.dataSource = self
        scroll.documentView = table
        content.addSubview(scroll)

        let cancel = NSButton(title: "ANNULER", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: width - 330, y: 20, width: 150, height: 32)
        content.addSubview(cancel)

        let validate = NSButton(title: "VALIDER LES MODIFICATIONS", target: self, action: #selector(validateTapped))
        validate.bezelStyle = .rounded
        validate.keyEquivalent = "\r"
        validate.frame = NSRect(x: width - 170, y: 20, width: 150, height: 32)
        content.addSubview(validate)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    @objc func cancelTapped() {
        window.close()          // aucune modification
    }

    @objc func validateTapped() {
        let plan = self.plan
        window.close()
        let result = applyPlan(plan)
        showAlert(title: "Bilan du traitement", text: Report.finalText(plan, result))
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let index = Int(tableColumn?.identifier.rawValue ?? "0") ?? 0
        return rows[row][index]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Gardées en vie tant que l'app tourne.
    private var controllers: [ValidationWindowController] = []
    private var receivedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Si l'app est lancée par double-clic (sans fichiers), on explique l'usage.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.receivedFiles == false {
                showAlert(title: "Renommage Audio",
                          text: "Glissez des fichiers MP3 ou WAV, ou des dossiers, sur l'icône de l'application.")
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedFiles = true
        let plan = buildPlan(paths: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
        guard !plan.entries.isEmpty else {
            showAlert(title: "Renommage Audio", text: "Aucun fichier MP3 ou WAV trouvé.")
            return
        }
        let controller = ValidationWindowController(plan: plan)
        controllers.append(controller)
        controller.show()
    }
}

let app = NSApplication.shared
// Variable globale : l'app ne retient pas son délégué, il doit donc rester référencé ici.
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
