import Cocoa

func fixtureImage(dark: Bool = false) -> CGImage {
    let size = NSSize(width: 1000, height: 720)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(white: dark ? 0.09 : 1, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    func bubble(_ top: CGFloat, _ height: CGFloat) {
        NSColor(white: dark ? 0.20 : 0.945, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 75, y: size.height - top - height, width: 850, height: height), xRadius: 15, yRadius: 15).fill()
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: dark ? NSColor.white : NSColor.black]
    func text(_ value: String, _ top: CGFloat) {
        (value as NSString).draw(at: CGPoint(x: 98, y: size.height - top - 30), withAttributes: attributes)
    }
    text("Alex · Today 10:30", 33)
    bubble(78, 235)
    text("Could we jump to the live meeting view by default?", 105)
    text("I shared the document, but stayed in the original view.", 142)
    text("When I scroll, participants cannot see the same position.", 225)
    text("这是同一条消息的第二段补充。", 263)
    text("Sam · Today 10:35", 354)
    bubble(400, 130)
    text("Another topic: Add shortcut to a document.", 423)
    text("This unrelated message should remain unchecked.", 465)
    text("2 replies     Summarize", 560)
    image.unlockFocus()
    var rect = CGRect(origin: .zero, size: size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

func requireTest(_ result: Bool, _ message: String) {
    if !result { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func runDetectionTests() throws {
    for dark in [false, true] {
        let image = fixtureImage(dark: dark)
        let frame = CGRect(x: -250, y: 125, width: 1000, height: 720)
        let lines = try recognize(image, frame: frame)
        let messages = candidateMessages(lines, image: image, frame: frame)
        guard let target = chooseTarget(messages, point: CGPoint(x: -80, y: 245)) else { requireTest(false, "No target"); return }
        requireTest(target.method == "气泡边界", "No bubble found in \(dark ? "dark" : "light") fixture: \(messages.map { "\($0.method): \($0.text)" })")
        requireTest(target.text.contains("participants"), "Second paragraph was dropped: \(target.rect) \(target.text)")
        requireTest(target.text.contains("第二段"), "Chinese paragraph was dropped")
        requireTest(!target.text.contains("Another topic"), "Adjacent topic merged into target")
        requireTest(checkedContext(messages, excluding: [target.id]).isEmpty, "Context must be opt-in")
        var toggled = messages
        guard let otherIndex = toggled.firstIndex(where: { $0.text.contains("Another topic") }) else { requireTest(false, "Other candidate missing"); return }
        toggled[otherIndex].included = true
        let context = checkedContext(toggled, excluding: [target.id])
        requireTest(context.contains("Another topic") && !context.contains("participants"), "Selected context export is wrong")
        toggled[otherIndex].included = false
        requireTest(checkedContext(toggled, excluding: [target.id]).isEmpty, "Deselected text leaked into context")
        requireTest(chooseTarget(messages, point: CGPoint(x: 3000, y: 3000)) == nil, "Far pointer selected a message")
        print("PASS: \(dark ? "dark" : "light") multi-paragraph bubble, separate adjacent topic, opt-in context, checkbox export, negative screen coordinates")
    }
    let lines = [TextItem(text: "First line of a plain email.", rect: CGRect(x: 40, y: 50, width: 330, height: 20)),
                 TextItem(text: "Second line of this paragraph.", rect: CGRect(x: 40, y: 77, width: 360, height: 20)),
                 TextItem(text: "A separate paragraph.", rect: CGRect(x: 40, y: 150, width: 250, height: 20))]
    let groups = candidateMessages(lines, image: nil, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    requireTest(groups.count == 2 && groups[0].text.contains("Second line"), "Plain text grouping failed")
    print("PASS: plain-text fallback preserves paragraph boundaries")
}

func regressionImage(_ path: String) throws {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { requireTest(false, "Cannot read regression image"); return }
    let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let items = try recognize(image, frame: frame)
    // The user screenshot includes the old result on the left and the source preview on the right.
    let candidates = candidateMessages(items, image: image, frame: frame)
    let point = CGPoint(x: frame.width * 0.65, y: frame.height * 0.595)
    guard let chosen = chooseTarget(candidates, point: point) else { requireTest(false, "No regression target"); return }
    let secondParagraph = items.filter { $0.rect!.minX > frame.width * 0.58 && $0.rect!.midY > frame.height * 0.615 && $0.rect!.midY < frame.height * 0.64 }
    requireTest(!secondParagraph.isEmpty && secondParagraph.allSatisfy { chosen.text.contains($0.text) }, "Regression: second paragraph still missing; method=\(chosen.method)")
    requireTest(chosen.rect.maxY < frame.height * 0.68, "Regression: bubble extends into next topic")
    requireTest(!chosen.text.localizedCaseInsensitiveContains("Add shortcut"), "Regression: unrelated topic included")
    print("PASS: attached screenshot — both paragraphs grouped, unrelated shortcut discussion excluded. Method: \(chosen.method).")
}

func documentRegressionImage(_ path: String) throws {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { requireTest(false, "Cannot read document image"); return }
    let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    // Inspect only the original source preview, not the duplicated results pane.
    let items = try recognize(image, frame: frame).filter { $0.rect!.minX > frame.width * 0.60 }
    let candidates = candidateMessages(items, image: image, frame: frame)
    guard let chosen = candidates.first(where: { $0.text.contains("A sofa represents") }) else {
        requireTest(false, "Missing document seed: \(candidates.map(\.text))"); return
    }
    let ids = documentTargetIDs(candidates, target: chosen)
    let text = candidates.filter { ids.contains($0.id) }.map(\.text).joined(separator: "\n\n")
    for phrase in ["Why Sofi", "Sofi is inspired", "A sofa represents", "You can simply", "From creating", "The idea behind", "even from the sofa"] {
        requireTest(text.contains(phrase), "Missing \(phrase): \(text)")
    }
    requireTest(!text.contains("Screenshots are never") && !text.contains("Ask Gemini") && !text.contains("Transition") && !text.contains("Genera"), "Chrome leaked into document")
    print("PASS: supplied screenshot captures title and all six paragraphs in reading order.\n\(text)")
}
