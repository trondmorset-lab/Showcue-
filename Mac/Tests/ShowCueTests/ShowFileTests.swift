import XCTest
@testable import ShowCue

/// Showfil laget av Windows-versjonen (ShowCue 0.4), brukt for å sikre at showfiler kan deles.
let windowsShowJSON = #"""
{
  "FormatVersion": 1,
  "Title": "Julekonsert",
  "Cues": [
    {
      "type": "audio",
      "FilePath": "D:\\Show\\Media\\walkin.wav",
      "FileChannels": 2,
      "Routes": [
        {
          "Source": 1,
          "Bus": 1,
          "GainDb": 0
        },
        {
          "Source": 2,
          "Bus": 2,
          "GainDb": 0
        },
        {
          "Source": 1,
          "Bus": 5,
          "GainDb": -6
        }
      ],
      "VolumeDb": -6,
      "StartTime": 0,
      "EndTime": 0,
      "Loop": true,
      "FadeIn": 2,
      "FadeOut": 3,
      "FileDuration": 180.5,
      "Number": "1",
      "Name": "Walk-in",
      "Notes": "",
      "PreWait": 0,
      "ContinueMode": "None",
      "Hotkey": "F1",
      "Disabled": false,
      "Color": "Blue",
      "MidiTrigger": ""
    },
    {
      "type": "fade",
      "Target": "1",
      "FadeTime": 5,
      "FadeAudio": true,
      "TargetDb": -60,
      "FadeVisual": true,
      "TargetOpacity": 0,
      "StopWhenDone": true,
      "Number": "2",
      "Name": "",
      "Notes": "",
      "PreWait": 0,
      "ContinueMode": "None",
      "Hotkey": "",
      "Disabled": false,
      "Color": "None",
      "MidiTrigger": ""
    },
    {
      "type": "video",
      "VolumeDb": -3,
      "FileChannels": 2,
      "Routes": null,
      "Loop": false,
      "KnownDuration": 92.4,
      "FilePath": "D:\\Show\\Media\\intro.mp4",
      "FadeIn": 0.5,
      "FadeOut": 0.5,
      "ReplaceOthers": true,
      "Stretch": "UniformToFill",
      "Number": "3",
      "Name": "",
      "Notes": "",
      "PreWait": 0,
      "ContinueMode": "AutoContinue",
      "Hotkey": "",
      "Disabled": false,
      "Color": "Purple",
      "MidiTrigger": ""
    },
    {
      "type": "osc",
      "Host": "192.168.1.50",
      "Port": 8000,
      "Address": "/eos/cue/1/fire",
      "Arguments": "1 \u0022to ord\u0022",
      "Number": "4",
      "Name": "",
      "Notes": "",
      "PreWait": 2,
      "ContinueMode": "None",
      "Hotkey": "",
      "Disabled": false,
      "Color": "None",
      "MidiTrigger": ""
    },
    {
      "type": "pdf",
      "Page": 3,
      "HoldTime": 10,
      "FilePath": "D:\\Show\\tekster.pdf",
      "FadeIn": 0.5,
      "FadeOut": 0.5,
      "ReplaceOthers": true,
      "Stretch": "Uniform",
      "Number": "5",
      "Name": "",
      "Notes": "",
      "PreWait": 0,
      "ContinueMode": "None",
      "Hotkey": "",
      "Disabled": false,
      "Color": "None",
      "MidiTrigger": ""
    },
    {
      "type": "image",
      "HoldTime": 0,
      "FilePath": "/Users/x/logo.png",
      "FadeIn": 0.5,
      "FadeOut": 0.5,
      "ReplaceOthers": false,
      "Stretch": "Uniform",
      "Number": "6",
      "Name": "",
      "Notes": "",
      "PreWait": 0,
      "ContinueMode": "None",
      "Hotkey": "",
      "Disabled": false,
      "Color": "None",
      "MidiTrigger": ""
    },
    {
      "type": "midi",
      "Device": "",
      "MessageType": "MscGo",
      "Channel": 1,
      "Data1": 60,
      "Data2": 127,
      "MscDeviceId": 127,
      "MscCommandFormat": 1,
      "MscCueNumber": "12.5",
      "Number": "7",
      "Name": "",
      "Notes": "",
      "PreWait": 0,
      "ContinueMode": "None",
      "Hotkey": "",
      "Disabled": false,
      "Color": "None",
      "MidiTrigger": "N:36"
    },
    {
      "type": "stop",
      "Target": "",
      "FadeTime": 3,
      "Number": "8",
      "Name": "",
      "Notes": "Siste",
      "PreWait": 0,
      "ContinueMode": "None",
      "Hotkey": "",
      "Disabled": true,
      "Color": "None",
      "MidiTrigger": ""
    }
  ]
}
"""#

final class ShowFileTests: XCTestCase {
    func testReadsWindowsShow() throws {
        let doc = try JSONDecoder().decode(ShowDocument.self, from: Data(windowsShowJSON.utf8))
        XCTAssertEqual(doc.cues.count, 8)
        let a = doc.cues[0]
        XCTAssertEqual(a.type, .audio)
        XCTAssertEqual(a.number, "1")
        XCTAssertEqual(a.volumeDb, -6)
        XCTAssertTrue(a.loop)
        XCTAssertEqual(a.hotkey, "F1")
        XCTAssertEqual(a.color, .blue)
        XCTAssertEqual(a.routes, [AudioRoute(1, 1), AudioRoute(2, 2), AudioRoute(1, 5, -6)])
        XCTAssertEqual(a.fileName, "walkin.wav") // Windows-sti
        XCTAssertEqual(doc.cues[1].type, .fade)
        XCTAssertEqual(doc.cues[1].target, "1")
        XCTAssertEqual(doc.cues[1].fadeTime, 5)
        let v = doc.cues[2]
        XCTAssertEqual(v.type, .video)
        XCTAssertEqual(v.volumeDb, -3)
        XCTAssertEqual(v.continueMode, .autoContinue)
        XCTAssertNil(v.routes)
        XCTAssertEqual(v.stretch, .uniformToFill)
        XCTAssertEqual(v.color, .purple)
        XCTAssertEqual(doc.cues[3].host, "192.168.1.50")
        XCTAssertEqual(doc.cues[3].port, 8000)
        XCTAssertEqual(doc.cues[3].arguments, "1 \"to ord\"")
        XCTAssertEqual(doc.cues[3].preWait, 2)
        XCTAssertEqual(doc.cues[4].page, 3)
        XCTAssertEqual(doc.cues[4].displayName, "tekster s.3")
        XCTAssertFalse(doc.cues[5].replaceOthers)
        XCTAssertEqual(doc.cues[6].messageType, .mscGo)
        XCTAssertEqual(doc.cues[6].mscCueNumber, "12.5")
        XCTAssertEqual(doc.cues[6].midiTrigger, "N:36")
        XCTAssertTrue(doc.cues[7].disabled)
        XCTAssertEqual(doc.cues[7].notes, "Siste")
    }

    func testRoundTripKeepsWindowsFieldNames() throws {
        let doc = try JSONDecoder().decode(ShowDocument.self, from: Data(windowsShowJSON.utf8))
        let data = try doc.jsonData()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["FormatVersion"] as? Int, 1)
        let cues = obj["Cues"] as! [[String: Any]]
        XCTAssertEqual(cues[0]["type"] as? String, "audio")
        XCTAssertEqual(cues[0]["VolumeDb"] as? Double, -6)
        XCTAssertEqual(cues[0]["ContinueMode"] as? String, "None")
        XCTAssertEqual(cues[2]["ContinueMode"] as? String, "AutoContinue")
        XCTAssertTrue(cues[2]["Routes"] is NSNull, "Routes null = standard, som Windows")
        XCTAssertEqual((cues[0]["Routes"] as? [[String: Any]])?.count, 3)
        XCTAssertNil(cues[1]["FilePath"], "bare relevante felt per type")
        let back = try JSONDecoder().decode(ShowDocument.self, from: data)
        XCTAssertEqual(try back.jsonData(), data, "samme show gir samme fil")
        XCTAssertEqual(try doc.jsonData(), data, "stabil rekkefølge")
    }

    func testLegacyVideoVolumePercent() throws {
        let json = #"{"Cues":[{"type":"video","FilePath":"a.mp4","Volume":50},{"type":"video","Volume":0},{"type":"video","VolumeDb":-2,"Volume":10}]}"#
        let doc = try JSONDecoder().decode(ShowDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.cues[0].volumeDb, -6.02, accuracy: 0.01)
        XCTAssertEqual(doc.cues[1].volumeDb, -60)
        XCTAssertEqual(doc.cues[2].volumeDb, -2, "VolumeDb vinner over gammel Volume")
    }

    func testDefaultsPerType() {
        XCTAssertEqual(Cue(type: .video).fadeIn, 0.5)
        XCTAssertEqual(Cue(type: .video).fileChannels, -1)
        XCTAssertEqual(Cue(type: .fade).fadeTime, 3)
        XCTAssertEqual(Cue(type: .stop).fadeTime, 0)
        XCTAssertEqual(Cue(type: .audio).fadeIn, 0)
    }

    func testSummaryAndDuration() {
        let a = Cue(type: .audio)
        a.filePath = "/x/walk.wav"; a.fileDuration = 100; a.startTime = 10; a.endTime = 40
        XCTAssertEqual(a.duration, 30)
        a.endTime = 0; XCTAssertEqual(a.duration, 90)
        a.loop = true; XCTAssertEqual(a.duration, 0)
        a.routes = [AudioRoute(1, 5), AudioRoute(2, 8)]
        XCTAssertTrue(a.summary.contains("ut 5,8"))
        let f = Cue(type: .fade); f.target = "3"
        XCTAssertTrue(f.summary.contains("−∞"))
        let h = Cue(type: .audio); h.hotkey = "f2"; h.midiTrigger = "N:61"
        XCTAssertEqual(h.hotkey, "F2")
        XCTAssertEqual(h.triggerText, "F2 · Note 61")
        XCTAssertEqual(TimeFormat.format(83.45), "01:23.4")
        XCTAssertEqual(TimeFormat.format(3725), "1:02:05")
    }

    func testNextPlayhead() {
        func list(_ m: [(ContinueMode, Bool)]) -> [Cue] { m.map { let c = Cue(type: .stop); c.continueMode = $0.0; c.disabled = $0.1; return c } }
        XCTAssertEqual(CueEngine.nextPlayheadIndex(list([(.none, false), (.none, false), (.none, false)]), fired: 0), 1)
        XCTAssertEqual(CueEngine.nextPlayheadIndex(list([(.autoContinue, false), (.autoFollow, false), (.none, false), (.none, false)]), fired: 0), 3)
        XCTAssertEqual(CueEngine.nextPlayheadIndex(list([(.none, false), (.none, true), (.none, false)]), fired: 0), 2)
        XCTAssertEqual(CueEngine.nextPlayheadIndex(list([(.none, false)]), fired: 0), 1)
    }
}
