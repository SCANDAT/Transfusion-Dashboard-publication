"""Index validated model, cohort and LOESS results for the dashboard."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import model_adapter as a
import release_format as f

def create(root, index_member, input_snapshot_sha256, package_sha256, methods_member):
    root = Path(root).resolve()
    for value in (input_snapshot_sha256, package_sha256):
        f.require(isinstance(value, str) and f.HEX.fullmatch(value), "INPUT_HASH_INVALID")
    destination = f.relative_path(root, index_member)
    f.require(destination.suffix == ".json" and not destination.exists(), "NEW_INDEX_REQUIRED")
    methods_path = f.relative_path(root, methods_member)
    f.require(methods_path.suffix == ".json", "METHODS_JSON_REQUIRED")
    methods_raw = methods_path.read_bytes()
    f.validate_methods(f.decode_json(methods_raw), a.method_shape())
    index = {"schemaVersion": a.INDEX_SCHEMA_V3, "cohortMode": "full_cohort",
             "inputSnapshotId": input_snapshot_sha256, "analysisPackageSHA256": package_sha256,
             "methods": {"path": methods_member, "sha256": f.digest(methods_raw)}, "models": [], "reports": [], "loess": None, "weekdays": []}
    checked = {methods_member: f.digest(methods_raw)}
    for plan in a.plan():
        job = plan["JobID"]
        directory = "models/" + job
        members = {key: directory + "/" + name for key, name in {
            "context": "context.json", "validation": "validation.json",
            "conversion": "decimal_csv/conversion.json"}.items()}
        exists = {key: f.relative_path(root, value).is_file() for key, value in members.items()}
        if not all(exists.values()):
            failed = f.relative_path(root, directory + "/validation_error.json").is_file()
            state = "failed" if failed else "pending"
            reason = "UNRESOLVED_VALIDATION" if failed else "AWAITING_VALIDATION_AND_CONVERSION"
            index["models"].append({"JobID": job, "state": state, "reasonCode": reason})
            continue
        documents, hashes = {}, {}
        for key, member in members.items():
            raw = f.relative_path(root, member).read_bytes()
            documents[key], hashes[key] = f.decode_json(raw), f.digest(raw)
            checked[member] = hashes[key]
        context, validation = documents["context"], documents["validation"]
        f.require(context.get("task") == "MODEL" and context.get("job") == plan, "CONTEXT_PLAN_MISMATCH")
        identity = context.get("identity", {})
        f.require(identity.get("CohortMode") == "full_cohort" and identity.get("InputSnapshotId") == input_snapshot_sha256, "FULL_COHORT_CONTEXT_REQUIRED")
        status = validation.get("validation", {}).get("status")
        reverse = {value: key for key, value in a.STATUS.items()}
        f.require(status in reverse, "VALIDATED_STATUS_REQUIRED")
        for key in ("CodeHash", "CertificateCodeHash"):
            f.require(isinstance(identity.get(key), str) and f.HEX.fullmatch(identity[key]), "RECORDED_SOURCE_HASH_REQUIRED")
        execution = str(identity.get("RunId", "")) + "-" + job
        f.require(f.TOKEN.fullmatch(execution), "EXECUTION_ID_INVALID")
        index["models"].append({
            "JobID": job, "state": reverse[status], "directory": directory,
            "contextSHA256": hashes["context"], "validationSHA256": hashes["validation"],
            "conversionSHA256": hashes["conversion"], "executionId": execution,
            "producingVersions": {"meanFitSHA256": identity["CodeHash"],
                                  "inferenceSHA256": identity["CertificateCodeHash"],
                                  "exportSHA256": identity["CodeHash"]},
        })
    from weekday_adapter import SELECTION_SCHEMA
    for plan in a.plan():
        if plan["FactorName"] != "wdy_donation":
            continue
        job = plan["JobID"]
        directory = "weekdays/" + job
        member = directory + "/selection.json"
        path = f.relative_path(root, member)
        if not path.is_file():
            failed = f.relative_path(root, directory + "/validation_error.json").is_file()
            index["weekdays"].append({"JobID": job, "state": "failed" if failed else "pending", "reasonCode": "UNRESOLVED_WEEKDAY_VALIDATION" if failed else "AWAITING_MONDAY_FRIDAY_SELECTION"})
            continue
        raw = path.read_bytes()
        selected = f.decode_json(raw)
        a.exact(selected, ("schemaVersion", "JobID", "contextSHA256", "executionSHA256", "validationSHA256", "conversionSHA256"), "WEEKDAY_RECEIPT_FIELDS")
        f.require(selected["schemaVersion"] == SELECTION_SCHEMA and selected["JobID"] == job, "WEEKDAY_RECEIPT_IDENTITY")
        checked[member] = f.digest(raw)
        for key, name in (("contextSHA256", "context.json"), ("executionSHA256", "execution.json"), ("validationSHA256", "validation.json"), ("conversionSHA256", "decimal_csv/conversion.json")):
            f.read_hash_bound(f.relative_path(root, directory + "/" + name), selected[key])
            checked[directory + "/" + name] = selected[key]
        index["weekdays"].append({"JobID": job, "state": "accepted", "directory": directory, "selectionSHA256": checked[member]})
    from supplement_adapter import REPORTS
    for job, directory, task in [
        *[(key, "reports/" + pop, "REPORT") for key, (_, pop) in REPORTS.items()],
        ("L_PRIMARY", "loess", "LOESS"),
    ]:
        members = {key: directory + "/" + name for key, name in {
            "context": "context.json", "validation": "validation.json",
            "conversion": "decimal_csv/conversion.json"}.items()}
        if not all(f.relative_path(root, value).is_file() for value in members.values()):
            failed = f.relative_path(root, directory + "/validation_error.json").is_file()
            entry = {"JobID": job, "state": "failed" if failed else "pending",
                     "reasonCode": "UNRESOLVED_VALIDATION" if failed else "AWAITING_VALIDATION_AND_CONVERSION"}
        else:
            documents, hashes = {}, {}
            for key, member in members.items():
                raw = f.relative_path(root, member).read_bytes()
                documents[key], hashes[key] = f.decode_json(raw), f.digest(raw)
                checked[member] = hashes[key]
            context, validation = documents["context"], documents["validation"]
            expected = context.get("expected", {})
            f.require(context.get("task") == task
                      and expected.get("CohortMode") == "full_cohort"
                      and expected.get("InputSnapshotId") == input_snapshot_sha256,
                      "SUPPLEMENT_CONTEXT_INVALID")
            f.require(validation.get("validation", {}).get("status") == "VALIDATED",
                      "SUPPLEMENT_VALIDATION_REQUIRED")
            analysis_hash = expected.get("CodeHash") if job == "R_PREPARATION" else expected.get("ReportCodeHash")
            export_hash = expected.get("ExportCodeHash")
            for sha in (analysis_hash, export_hash):
                f.require(isinstance(sha, str) and f.HEX.fullmatch(sha), "SUPPLEMENT_SOURCE_HASH_REQUIRED")
            entry = {"JobID": job, "state": "accepted", "directory": directory,
                     "contextSHA256": hashes["context"], "validationSHA256": hashes["validation"],
                     "conversionSHA256": hashes["conversion"], "executionId": expected["ExportId"],
                     "producingVersions": {"analysisSHA256": analysis_hash, "exportSHA256": export_hash}}
        if task == "REPORT": index["reports"].append(entry)
        else: index["loess"] = entry
    for member, digest in checked.items():
        f.read_hash_bound(f.relative_path(root, member), digest)
    with destination.open("xb") as stream:
        stream.write(f.encode(index))
    return {"status": "RESULTS_INDEX_CREATED", "models": len(index["models"]),
            "indexSHA256": f.digest(destination.read_bytes())}

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-root", required=True, type=Path)
    parser.add_argument("--index", default="results.json")
    parser.add_argument("--input-snapshot-sha256", required=True)
    parser.add_argument("--analysis-package-sha256", required=True)
    parser.add_argument("--methods", default="methods.json")
    args = parser.parse_args(argv)
    try:
        result = create(args.input_root, args.index, args.input_snapshot_sha256,
                        args.analysis_package_sha256, args.methods)
    except (OSError, ValueError, TypeError, KeyError):
        print("RESULTS_INDEX_REJECTED")
        return 1
    print(json.dumps(result))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

