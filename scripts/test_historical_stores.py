#!/usr/bin/env python3
"""Compile shipped schema sources; write/migrate/reopen in separate iOS Simulator processes.

Only disposable stores with opaque test markers are used. This tests compiled schema
compatibility, not real device signing or semantic decoding of a user's records.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "Sources/PersonalFitness/Storage/StorageSchema.swift"
VERSIONS = [("V1", "230c194"), ("V2", "0a904be"), ("V3", "514c03d"), ("V4", "9be0e8b")]
FIELDS = {
    2: ["coachData", "favoriteIDsData"],
    3: ["planningDraftsData", "weeklyProgramsData", "deletedPlanIDsData", "deletedProgramIDsData"],
    4: ["interviewData", "checkInsData", "feedbackData", "healthSnapshotData", "adjustmentsData", "reviewSummariesData", "readinessData"],
}


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs)


def swift_source(version, writing):
    n = int(version[1:])
    model = "FitnessSchema" + (version if writing else "V4")
    fields = [f for level, names in FIELDS.items() if level <= n for f in names]
    assignments = "\n".join('root.%s = Data("marker-%s".utf8)' % (f, f) for f in fields)
    assertions = "\n".join('precondition(root.%s == Data("marker-%s".utf8))' % (f, f) for f in fields)
    migration = "" if writing else ", migrationPlan: FitnessMigrationPlan.self"
    operation = '''
        let root = StoreSchema.MetadataRecord(profileData: marker, customExercisesData: marker, activePlanVersionID: id)
        %s
        context.insert(root)
        context.insert(StoreSchema.PlanVersionRecord(id: id, planID: id, version: 1, confirmedAt: date, payload: marker))
        context.insert(StoreSchema.SessionRecord(id: id, startedAt: date, status: "finished", revision: 1, payload: marker))
        try context.save()
    ''' % assignments if writing else '''
        let roots = try context.fetch(FetchDescriptor<StoreSchema.MetadataRecord>())
        precondition(roots.count == 1)
        let root = roots[0]
        precondition(root.profileData == marker && root.customExercisesData == marker && root.activePlanVersionID == id)
        %s
        let plans = try context.fetch(FetchDescriptor<StoreSchema.PlanVersionRecord>())
        let sessions = try context.fetch(FetchDescriptor<StoreSchema.SessionRecord>())
        precondition(plans.count == 1 && sessions.count == 1)
        precondition(plans[0].id == id && plans[0].planID == id && plans[0].version == 1 && plans[0].confirmedAt == date && plans[0].payload == marker)
        precondition(sessions[0].id == id && sessions[0].startedAt == date && sessions[0].revision == 1 && sessions[0].payload == marker)
    ''' % assertions
    return '''
import Foundation
import SwiftData
typealias StoreSchema = %s
@main @MainActor struct StoreProbe {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema(versionedSchema: StoreSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema%s, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let marker = Data("historical-schema-opaque-marker".utf8)
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let date = Date(timeIntervalSince1970: 1790000000)
        %s
        print("PASS %s %s")
    }
}
''' % (model, migration, operation, version, "write" if writing else "migrate-and-reopen")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="fitness-historical-stores-") as name:
        base = Path(name)
        for version, commit in VERSIONS:
            historical = subprocess.check_output(["git", "show", commit + ":" + SCHEMA], cwd=ROOT)
            schema_file = base / (version + "Schema.swift")
            schema_file.write_bytes(historical)
            store = base / (version + ".store")
            for writing in (True, False):
                label = version + ("-writer" if writing else "-reader")
                main_file = base / (label + ".swift")
                main_file.write_text(swift_source(version, writing), encoding="utf-8")
                binary = base / label
                run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-sdk", sdk,
                     "-target", "arm64-apple-ios27.0-simulator", "-swift-version", "6", "-O",
                     "-parse-as-library", "-module-name", "PersonalFitness",
                     schema_file if writing else ROOT / SCHEMA, main_file, "-o", binary])
                run(["codesign", "--force", "--sign", "-", binary])
                run(["xcrun", "simctl", "spawn", args.device, binary, store])
                if not writing:
                    run(["xcrun", "simctl", "spawn", args.device, binary, store])
            print("VERIFIED %s: shipped source %s -> current schema -> second cold open" % (version, commit), flush=True)


if __name__ == "__main__":
    main()
