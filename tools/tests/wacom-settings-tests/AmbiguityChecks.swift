// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks that the import reads nothing the backup leaves in doubt: workflow
// sets, a set or pen entry listed twice, and a key, pen button, or ring mode
// listed twice or with two functions. No real backup has these, so the
// backup here is made up inline.

import Foundation

private let doubtful = """
<?xml version="1.0" encoding="UTF-8"?>
<root type="map">
  <ImportFileVersion type="integer">6</ImportFileVersion>
  <OSInterface type="map"><ApplicationMap type="map">
    <AppID0 type="map"><ApplicationName type="string">All applications</ApplicationName></AppID0>
    <AppID1 type="map"><ApplicationName type="string">One</ApplicationName>
      <ApplicationSecondaryId type="string">com.example.one</ApplicationSecondaryId></AppID1>
    <AppID2 type="map"><ApplicationName type="string">Two</ApplicationName>
      <ApplicationSecondaryId type="string">com.example.two</ApplicationSecondaryId></AppID2>
  </ApplicationMap></OSInterface>
  <TabletArray type="array">
    <ArrayElement type="map">
      <DefaultTabName type="string">Intuos Pro M</DefaultTabName>
      <SensorID type="integer">90833751</SensorID>
      <TabletControlContainerArray type="array">
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">0</ApplicationAssociated>
          <WorkflowAssociated type="integer">1</WorkflowAssociated>
          <TabletControlsButtonsArray type="array">
            <ArrayElement type="map"><ButtonName type="string">LeftButton1</ButtonName>
              <ButtonFunction type="integer">3</ButtonFunction></ArrayElement>
          </TabletControlsButtonsArray>
        </ArrayElement>
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">0</ApplicationAssociated>
          <WorkflowAssociated type="integer">0</WorkflowAssociated>
          <TabletControlsButtonsArray type="array">
            <ArrayElement type="map"><ButtonName type="string">LeftButton1</ButtonName>
              <ButtonFunction type="integer">1</ButtonFunction></ArrayElement>
            <ArrayElement type="map"><ButtonName type="string">LeftButton2</ButtonName>
              <ButtonFunction type="integer">2</ButtonFunction></ArrayElement>
            <ArrayElement type="map"><ButtonName type="string">LeftButton2</ButtonName>
              <ButtonFunction type="integer">4</ButtonFunction></ArrayElement>
            <ArrayElement type="map"><ButtonName type="string">LeftButton3</ButtonName>
              <ButtonFunction type="integer">1</ButtonFunction>
              <ButtonFunction type="integer">3</ButtonFunction></ArrayElement>
          </TabletControlsButtonsArray>
          <TouchRingSettings type="map"><TouchStripModes type="map">
            <mode1 type="map"><TouchStripFunction type="integer">45</TouchStripFunction></mode1>
            <mode2 type="map"><TouchStripFunction type="integer">45</TouchStripFunction>
              <TouchStripFunction type="integer">51</TouchStripFunction></mode2>
          </TouchStripModes></TouchRingSettings>
        </ArrayElement>
        <ArrayElement type="map"><ApplicationAssociated type="integer">1</ApplicationAssociated></ArrayElement>
        <ArrayElement type="map"><ApplicationAssociated type="integer">1</ApplicationAssociated></ArrayElement>
      </TabletControlContainerArray>
      <TabletTransducerArray type="array">
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">0</ApplicationAssociated>
          <TransducerID type="map"><Sequence type="integer">2864434397</Sequence><Type type="integer">2114</Type></TransducerID>
          <TransducerLowerButtonSettings type="map">
            <ButtonFunction type="integer">2</ButtonFunction>
            <ButtonFunction type="integer">3</ButtonFunction>
          </TransducerLowerButtonSettings>
          <TransducerUpperButtonSettings type="map"><ButtonFunction type="integer">3</ButtonFunction></TransducerUpperButtonSettings>
        </ArrayElement>
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">0</ApplicationAssociated>
          <TransducerID type="map"><Sequence type="integer">287454020</Sequence><Type type="integer">2114</Type></TransducerID>
          <TransducerUpperButtonSettings type="map"><ButtonFunction type="integer">3</ButtonFunction></TransducerUpperButtonSettings>
        </ArrayElement>
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">0</ApplicationAssociated>
          <TransducerID type="map"><Sequence type="integer">287454020</Sequence><Type type="integer">2114</Type></TransducerID>
          <TransducerUpperButtonSettings type="map"><ButtonFunction type="integer">2</ButtonFunction></TransducerUpperButtonSettings>
        </ArrayElement>
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">2</ApplicationAssociated>
          <TransducerID type="map"><Sequence type="integer">2864434397</Sequence><Type type="integer">2114</Type></TransducerID>
          <TransducerUpperButtonSettings type="map"><ButtonFunction type="integer">2</ButtonFunction></TransducerUpperButtonSettings>
        </ArrayElement>
        <ArrayElement type="map">
          <ApplicationAssociated type="integer">2</ApplicationAssociated>
          <TransducerID type="map"><Sequence type="integer">287454020</Sequence><Type type="integer">2114</Type></TransducerID>
          <TransducerUpperButtonSettings type="map"><ButtonFunction type="integer">1</ButtonFunction></TransducerUpperButtonSettings>
        </ArrayElement>
      </TabletTransducerArray>
    </ArrayElement>
    <ArrayElement type="map">
      <DefaultTabName type="string">Intuos Pro L</DefaultTabName>
      <SensorID type="integer">90833752</SensorID>
      <TabletControlContainerArray type="array">
        <ArrayElement type="map"><ApplicationAssociated type="integer">0</ApplicationAssociated>
          <TabletControlsButtonsArray type="array">
            <ArrayElement type="map"><ButtonName type="string">LeftButton1</ButtonName>
              <ButtonFunction type="integer">1</ButtonFunction></ArrayElement>
          </TabletControlsButtonsArray></ArrayElement>
        <ArrayElement type="map"><ApplicationAssociated type="integer">0</ApplicationAssociated>
          <TabletControlsButtonsArray type="array">
            <ArrayElement type="map"><ButtonName type="string">LeftButton1</ButtonName>
              <ButtonFunction type="integer">3</ButtonFunction></ArrayElement>
          </TabletControlsButtonsArray></ArrayElement>
      </TabletControlContainerArray>
    </ArrayElement>
  </TabletArray>
</root>
"""

func checkAmbiguity(layout: @escaping LayoutLookup, _ expect: (Bool, String) -> Void) {
    guard let root = (try? XMLDocument(xmlString: doubtful, options: []))?.rootElement() else {
        expect(false, "Doubtful backup parses")
        return
    }
    let report = WacomMapper.report(WacomBackup(driverVersion: "6.4.15-1", root: WacomNode(root)), layout: layout)
    guard report.tablets.count == 2 else {
        expect(false, "Two tablets: \(report.tablets.count)")
        return
    }
    let pth = report.tablets[0]
    func app(_ name: String) -> AppReport? { pth.apps.first { $0.name == name } }
    func lines(_ app: String, _ section: String, _ control: String) -> [Line] {
        pth.apps.first { $0.name == app }?.sections.first { $0.title.hasPrefix(section) }?
            .lines.filter { $0.control == control } ?? []
    }
    func line(_ app: String, _ section: String, _ control: String) -> Line? { lines(app, section, control).first }
    func inDoubt(_ l: Line?) -> Bool {
        guard let l, case .skipped(let r) = l.outcome else { return false }
        return r.contains("doesn't say which counts") && l.setting == nil && l.action == nil
    }

    // Workflow sets
    expect(pth.notes.contains { $0.contains("1 workflow set skipped") }, "Workflow set noted: \(pth.notes)")
    expect(line("All applications", "ExpressKeys", "LeftButton1")?.action == .binding(.kind("leftClick")),
           "All applications comes from the set outside the workflow")

    // Keys, ring modes, and pen buttons in doubt
    let twice = lines("All applications", "ExpressKeys", "LeftButton2")
    expect(twice.count == 2 && twice.allSatisfy(inDoubt), "A key listed twice is left alone, both entries")
    expect(inDoubt(line("All applications", "ExpressKeys", "LeftButton3")), "A key with two functions is left alone")
    expect(inDoubt(line("All applications", "Touch ring", "mode2")), "A ring mode with two functions is left alone")
    expect(line("All applications", "Touch ring", "mode1")?.action == .ring(.scroll, label: nil), "Its other mode reads")
    expect(inDoubt(line("All applications", "Pen 0xAABBCCDD", "Lower button")), "A pen button with two functions is left alone")
    expect(line("All applications", "Pen 0xAABBCCDD", "Upper button")?.action == .binding(.kind("rightClick")),
           "The pen's other button reads")

    // Sets and pens listed twice
    let sections = app("All applications")?.sections ?? []
    expect(!sections.contains { $0.pen == 0x11223344 }, "A pen listed twice in All applications isn't read")
    expect(pth.notes.contains { $0.contains("0x11223344") && $0.contains("All applications") }, "Doubled pen noted: \(pth.notes)")
    expect(app("One")?.notes.contains { $0.contains("Two control sets") } == true, "An app with two sets is skipped")
    expect(app("Two")?.sections.contains { $0.pen == 0xAABBCCDD } == true, "An app keeps its clear pen")
    expect(app("Two")?.sections.contains { $0.pen == 0x11223344 } == false,
           "An app drops a pen whose All applications entry is doubled")

    // What the encoder writes from it
    if let enc = try? WacomEncoder.encode(pth) {
        let pen = enc.pens.first { $0.serial == 0xAABBCCDD }
        expect(pen != nil && pen?.values["penButton1Binding"] == nil, "The doubtful pen button keeps its setting")
        expect(pen?.values["penButton2Binding"] != nil, "The clear pen button is written")
        expect(!enc.pens.contains { $0.serial == 0x11223344 }, "The doubled pen gets no settings")
        expect(!enc.apps.contains { $0.bundleID == "com.example.one" }, "The app with two sets gets no settings")
    } else {
        expect(false, "The doubtful tablet encodes")
    }

    let pthL = report.tablets[1]
    expect(pthL.notes.contains { $0.contains("Two All applications sets") }, "Two All applications sets noted")
    expect(!(pthL.apps.first?.sections.contains { $0.title == "ExpressKeys" } ?? true), "No controls read from them")
}
