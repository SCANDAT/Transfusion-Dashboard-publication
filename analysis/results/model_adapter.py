"""Build dashboard tables from validated, converted full-cohort aggregate results."""
from __future__ import annotations
import argparse
import csv
import hashlib
import io
import itertools
import json
import os
from pathlib import Path
import re
import sys
import uuid
import release_format as f

f.require(sys.version_info >= (3, 12), "PYTHON_312_REQUIRED")

HERE = Path(__file__).resolve().parent
SCHEMA = json.loads((HERE / "model_schema.json").read_text(encoding="utf-8"))
INDEX_SCHEMA = "transfusion-analysis/results-index-v2"
INDEX_SCHEMA_V3 = "transfusion-analysis/results-index-v3"
STATUS = {
    "accepted": "VALIDATED",
    "inference_unavailable": "EXPECTED_INFERENCE_UNAVAILABLE_VALIDATED",
    "prefit_unavailable": "EXPECTED_UNAVAILABLE_VALIDATED",
}
PREFIT_REASONS = set("EMPTY_MODEL_INPUT NO_OUTCOME_WINDOW_ROWS NO_COMPLETE_MODEL_ROWS INSUFFICIENT_COMPLETE_ROWS INSUFFICIENT_PERSONS DECLARED_REFERENCE_LEVEL_ABSENT FACTOR_AVAILABLE_CATEGORIES_LT2".split())
MODEL_FIELDS = ("JobID", "FitId", "PopulationId", "Model", "FactorName", "VitalCode")
IDENTITY_FIELDS = ("RunId", "AnalysisSpecId", "CohortMode", "InputSnapshotId", "CodeHash", "ConfigHash")
PROFILE_IDENTITY = ("RunId", "AnalysisSpecId", "CohortMode", "PopulationId", "FitId", "InputSnapshotId", "CodeHash", "ConfigHash", "DesignId", "ProfileId", "JobID", "ProfileIdentityKind")

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii")

def exact(value, keys, code):
    f.require(isinstance(value, dict) and set(value) == set(keys), code)

def no_private_text(value):
    f.require(isinstance(value, str) and not any(ord(ch) < 32 for ch in value), "INVALID_TEXT")
    f.require(re.search(r"(?i)([a-z]:[\\/]|\\\\|file://|https?://|\.sas7bdat\b|\.sas7bndx\b)", value) is None, "PRIVATE_LOCATION_OR_SOURCE_MEMBER")

def plan():
    with (HERE / "models.csv").open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream))
    f.require(len(rows) == 252 and len({r["JobID"] for r in rows}) == 252, "MODEL_PLAN_INVALID")
    expected = set(itertools.product(f.POPULATIONS, f.MODELS, f.FACTOR_MAP.values(), f.OUTCOMES))
    actual = set()
    for row in rows:
        exact(row, MODEL_FIELDS, "MODEL_PLAN_FIELDS")
        key = f.fit_key(dict(row, InferencePrefix="C" + row["JobID"][1:]))
        actual.add(tuple(key.values()))
    f.require(actual == expected, "MODEL_UNIVERSE_INCOMPLETE")
    return rows

def method_shape():
    names = ("AuthoritativeInference", "Availability", "IdentityAndEligibility", "ObservedPairedSummaries", "ResidualAndOtherLimits")
    return {**{key: f.METHOD_FIELDS[key] for key in names},
            **{key: str for key in ("PrimaryModel", "ComparisonModel", "ReferenceProfile", "SedativeEncoding", "TimeSupport", "LOESS", "RetentionReplay")}}

class Results:
    def __init__(self, root, index_member, index_sha256):
        self.root = Path(root).resolve()
        f.require(self.root.is_dir(), "INPUT_DIRECTORY_REQUIRED")
        self.used = {}
        self.index_sha = index_sha256
        self.index = self.bound(index_member, index_sha256, json_file=True)
        index_fields = ("schemaVersion", "cohortMode", "inputSnapshotId", "analysisPackageSHA256", "methods", "models", "reports", "loess")
        exact(self.index, index_fields + (("weekdays",) if self.index.get("schemaVersion") == INDEX_SCHEMA_V3 else ()), "INDEX_FIELDS_INVALID")
        f.require(self.index["schemaVersion"] in (INDEX_SCHEMA, INDEX_SCHEMA_V3) and self.index["cohortMode"] == "full_cohort", "FULL_COHORT_INDEX_REQUIRED")
        for key in ("inputSnapshotId", "analysisPackageSHA256"):
            f.require(isinstance(self.index[key], str) and f.HEX.fullmatch(self.index[key]), "INDEX_HASH_INVALID")
        self.plans = {row["JobID"]: row for row in plan()}
        self.entries = {}
        f.require(isinstance(self.index["models"], list), "MODEL_INDEX_REQUIRED")
        for entry in self.index["models"]:
            f.require(isinstance(entry, dict) and entry.get("JobID") in self.plans and entry["JobID"] not in self.entries, "MODEL_SELECTION_INVALID")
            state = entry.get("state")
            f.require(state in set(STATUS) | {"pending", "failed"}, "MODEL_STATE_INVALID")
            if state in STATUS:
                exact(entry, ("JobID", "state", "directory", "contextSHA256", "validationSHA256", "conversionSHA256", "executionId", "producingVersions"), "ACCEPTED_ENTRY_FIELDS")
                f.require(isinstance(entry["executionId"], str) and f.TOKEN.fullmatch(entry["executionId"]), "EXECUTION_ID_INVALID")
                exact(entry["producingVersions"], ("meanFitSHA256", "inferenceSHA256", "exportSHA256"), "PRODUCING_VERSIONS_REQUIRED")
                for value in entry["producingVersions"].values():
                    f.require(isinstance(value, str) and f.HEX.fullmatch(value), "PRODUCING_VERSION_INVALID")
                f.relative_path(self.root, entry["directory"])
            else:
                exact(entry, ("JobID", "state", "reasonCode"), "UNSELECTED_ENTRY_FIELDS")
                f.require(isinstance(entry["reasonCode"], str) and f.REASON.fullmatch(entry["reasonCode"]), "REASON_CODE_INVALID")
            self.entries[entry["JobID"]] = entry
        f.require(set(self.entries) == set(self.plans), "EXPLICIT_252_STATES_REQUIRED")
        methods = self.index["methods"]
        exact(methods, ("path", "sha256"), "METHODS_BINDING_REQUIRED")
        self.methods = self.bound(methods["path"], methods["sha256"], json_file=True)
        f.validate_methods(self.methods, method_shape())
        from supplement_adapter import Supplements
        self.supplements = Supplements(self, no_private_text)
        from weekday_adapter import Weekdays
        self.weekdays = Weekdays(self)

    def bound(self, member, sha256, *, json_file=False):
        path = f.relative_path(self.root, member)
        f.require(path.suffix.lower() in {".csv", ".json"}, "AGGREGATE_METADATA_ONLY")
        raw = f.read_hash_bound(path, sha256)
        self.used[member] = {"sha256": sha256, "size": len(raw)}
        return f.decode_json(raw) if json_file else raw

    def selection(self, job):
        entry = self.entries[job]
        directory = entry["directory"]
        context = self.bound(directory + "/context.json", entry["contextSHA256"], json_file=True)
        validation = self.bound(directory + "/validation.json", entry["validationSHA256"], json_file=True)
        conversion = self.bound(directory + "/decimal_csv/conversion.json", entry["conversionSHA256"], json_file=True)
        f.require(context.get("task") == "MODEL" and context.get("job") == self.plans[job], "CONTEXT_PLAN_MISMATCH")
        f.require(validation.get("contextHash") == f.digest(canonical(context)), "VALIDATION_CONTEXT_MISMATCH")
        result = validation.get("validation", {})
        f.require(result.get("status") == STATUS[entry["state"]], "VALIDATION_STATUS_MISMATCH")
        f.require(conversion.get("numericFormat") == "PY_REPR_BINARY64"
                  and conversion.get("validationSha256") == entry["validationSHA256"]
                  and conversion.get("publicReleaseAuthorized") is False, "CONVERSION_BINDING_MISMATCH")
        identity, expected = context.get("identity", {}), context.get("expected", {})
        f.require(identity.get("CohortMode") == "full_cohort" and identity.get("InputSnapshotId") == self.index["inputSnapshotId"], "MODEL_COHORT_MISMATCH")
        f.require(all(expected.get(key) == value for key, value in self.plans[job].items()), "EXPECTED_PLAN_MISMATCH")
        f.require(all(expected.get(key) == identity.get(key) for key in IDENTITY_FIELDS), "EXPECTED_IDENTITY_MISMATCH")
        f.require(isinstance(identity.get("RunId"), str) and re.fullmatch(r"[a-f0-9]{32}", identity["RunId"]), "ORIGINAL_RUN_ID_INVALID")
        for key in ("JobID", "FitId", "DesignId", "ProfileId"):
            f.require(isinstance(expected.get(key), str) and f.TOKEN.fullmatch(expected[key]), "ORIGINAL_MODEL_ID_INVALID")
        for key in ("CodeHash", "ConfigHash", "InputSnapshotId", "PreparationReceiptHash"):
            f.require(isinstance(identity.get(key), str) and f.HEX.fullmatch(identity[key]), "IDENTITY_HASH_REQUIRED")
        exact(result.get("inputHashes"), ("working", "robust"), "VALIDATED_INPUT_HASHES_REQUIRED")
        known = {}
        for group, folder in (("working", "model_csv"), ("robust", "inference_csv")):
            f.require(isinstance(result["inputHashes"][group], dict), "VALIDATED_HASH_MAP_INVALID")
            for name, digest in result["inputHashes"][group].items():
                f.require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_]+\.csv", name)
                          and isinstance(digest, str) and f.HEX.fullmatch(digest), "VALIDATED_MEMBER_INVALID")
                known[folder + "/" + name] = digest
        converted = {}
        for binding in conversion.get("files", []):
            exact(binding, ("file", "sourceSha256", "decimalSha256"), "CONVERSION_FILE_FIELDS")
            name = binding["file"]
            f.require(isinstance(name, str) and name in known and name not in converted
                      and binding["sourceSha256"] == known[name], "CONVERSION_SOURCE_MISMATCH")
            f.require(isinstance(binding["decimalSha256"], str) and f.HEX.fullmatch(binding["decimalSha256"]), "CONVERSION_HASH_INVALID")
            converted[name] = binding
        f.require(set(converted) == set(known), "CONVERSION_INCOMPLETE")
        return Model(self, entry, context, converted)

    def unchanged(self):
        for member, binding in self.used.items():
            path = f.relative_path(self.root, member)
            f.require(path.is_file() and path.stat().st_size == binding["size"], "BOUND_SIZE_MISMATCH")
            with path.open("rb") as stream:
                actual = hashlib.file_digest(stream, "sha256").hexdigest()
            f.require(actual == binding["sha256"], "BOUND_HASH_MISMATCH")

class Model:
    def __init__(self, results, entry, context, converted):
        self.results, self.entry, self.context, self.converted = results, entry, context, converted
        self.plan = context["job"]
        self.job = self.plan["JobID"]
        self.prefix = "C" + self.job[1:]
        self.identity = None

    def table(self, layer, role, *, identity=None):
        f.require(layer in ("inference", "inference_unavailable", "working"), "LAYER_NOT_ALLOWED")
        allowed = {
            "inference": set(f.ROLES) | {"identity", "status", "cat_availability"},
            "inference_unavailable": {"identity", "status", "cat_availability"},
            "working": {"identity", "job_status", "cat_availability"},
        }
        f.require(role in allowed[layer], "PRIVATE_ROLE_FORBIDDEN")
        definition = SCHEMA[layer][role]
        folder = "model_csv" if layer == "working" else "inference_csv"
        prefix = self.job if layer == "working" else self.prefix + ("_iu" if layer == "inference_unavailable" else "")
        return self.read_table(folder + "/" + prefix + "_" + role + ".csv",
                               definition["Columns"], definition.get("NumericColumns", []), identity=identity)

    def read_table(self, member, columns, numeric, *, identity=None):
        f.require(member in self.converted, "MISSING_CONVERTED_ROLE")
        binding = self.converted[member]
        raw = self.results.bound(self.entry["directory"] + "/decimal_csv/" + member, binding["decimalSha256"])
        try:
            header = next(csv.reader(io.StringIO(raw.decode("utf-8-sig"), newline=""), strict=True))
        except (StopIteration, UnicodeError, csv.Error):
            raise f.NormalizationError("INVALID_ROLE_HEADER") from None
        f.require(len(header) == len(columns) and set(header) == set(columns), "ROLE_SCHEMA_MISMATCH")
        rows = f.parse_csv(raw, header, set(numeric))
        expected = self.context["expected"]
        for row in rows:
            for field in columns:
                if field not in numeric:
                    no_private_text(row[field])
            f.require(all(row.get(key) == expected[key] for key in IDENTITY_FIELDS + ("JobID", "FitId", "PopulationId", "DesignId", "ProfileId")), "ROLE_IDENTITY_MISMATCH")
            if identity is not None:
                f.require(all(row.get(key) == value for key, value in identity.items()), "ROLE_CONTEXT_MISMATCH")
        return columns, rows, binding["decimalSha256"]

    def state(self):
        layer = "inference" if self.entry["state"] == "accepted" else "inference_unavailable" if self.entry["state"] == "inference_unavailable" else "working"
        _, identities, _ = self.table(layer, "identity")
        f.require(len(identities) == 1, "ONE_IDENTITY_REQUIRED")
        self.identity = identities[0]
        _, rows, _ = self.table(layer, "job_status" if layer == "working" else "status", identity=self.identity)
        f.require(len(rows) == 1, "ONE_STATUS_REQUIRED")
        status = rows[0]
        _, availability, _ = self.table(layer, "cat_availability", identity=self.identity)
        expected_codes = SCHEMA["factorLevels"][self.plan["FactorName"]]
        f.require([row["CategoryCode"] for row in availability] == expected_codes, "CATEGORY_PLAN_MISMATCH")
        f.require(all(row["Available"] in (0, 1) for row in availability), "CATEGORY_AVAILABILITY_INVALID")
        if layer == "working":
            f.require(status["JobStatus"] == "EXPECTED_UNAVAILABLE" and status["FitAttempted"] == 0 and status["ReasonCode"] in PREFIT_REASONS, "PREFIT_UNAVAILABLE_INVALID")
            return status["ReasonCode"]
        if layer == "inference_unavailable":
            f.require(self.identity["InferenceStatus"] == "CR2_INFERENCE_UNAVAILABLE"
                      and status["IntegrationStatus"] == "EXPECTED_INFERENCE_UNAVAILABLE"
                      and status["ReasonCode"] == "PLANNED_TARGET_NOT_LOO_ESTIMABLE", "STRUCTURAL_UNAVAILABLE_INVALID")
            return status["ReasonCode"]
        f.require(self.identity["InferenceStatus"] == "CR2_CHECKS_PASSED"
                  and self.identity["CovarianceMethod"] == "GLS_WHITENED_CR2"
                  and status["IntegrationStatus"] == "CR2_CHECKS_PASSED"
                  and status["ReasonCode"] == "PASS", "ROBUST_INFERENCE_REQUIRED")
        return None

    def profile(self, release_id, key):
        definition = SCHEMA["profiles"][self.plan["Model"]]
        member = "model_csv/" + self.job + "_profile.csv"
        _, rows, source_sha = self.read_table(member, definition["NativeColumns"], definition["NativeNumericColumns"])
        f.require(len(rows) == 1, "ONE_REFERENCE_PROFILE_REQUIRED")
        native = rows[0]
        f.require(all(native[field] == self.identity[field] for field in PROFILE_IDENTITY), "PROFILE_IDENTITY_MISMATCH")
        row = {field: native[field] for field in definition["Columns"] if field in native}
        row.update(SelectedAttemptId=self.entry["executionId"], **{k: self.plan[k] for k in ("Model", "FactorName", "VitalCode")},
                   ReferenceProfileStatus="MODEL_REFERENCE_PROFILE",
                   ConstructionId="VALIDATED_PROFILE_COLUMN_SELECTION_V1", SourceProfileSHA256=source_sha)
        f.require(set(row) == set(definition["Columns"]), "PROFILE_FIELDS_MISMATCH")
        return {"schemaVersion": f.PROFILE_TABLE_SCHEMA, "releaseId": release_id, "key": key,
                "profileId": row["ProfileId"], "sourceSha256": source_sha,
                **f.pack_columns(definition["Columns"], [row])}

def normalize(root, index_member, index_sha256, output, release_id, receipt):
    f.require(isinstance(release_id, str) and f.TOKEN.fullmatch(release_id), "RELEASE_ID_INVALID")
    source_members = ("model_adapter.py", "release_format.py", "model_schema.json", "models.csv", "supplement_adapter.py", "supplement_schema.json", "weekday_adapter.py", "weekday_schema.json")
    source_hashes = {name: f.digest((HERE / name).read_bytes()) for name in source_members}
    results = Results(root, index_member, index_sha256)
    output, receipt = Path(output).absolute(), Path(receipt).absolute()
    f.require(not output.exists() and not receipt.exists(), "OUTPUT_ALREADY_EXISTS")
    f.require(not output.resolve().is_relative_to(results.root) and not results.root.is_relative_to(output.resolve()), "INPUT_OUTPUT_OVERLAP")
    f.require(not receipt.resolve().is_relative_to(output.resolve()), "PRIVATE_RECEIPT_REQUIRED")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = output.parent / (".models-" + uuid.uuid4().hex + ".incomplete")
    stage.mkdir()
    assets = stage / "data" / "releases" / release_id
    assets.mkdir(parents=True)
    written = {}
    def write(name, value):
        raw = f.encode(value)
        target = assets / name
        with target.open("xb") as stream: stream.write(raw)
        rel = target.relative_to(stage).as_posix()
        written[rel] = {"sha256": f.digest(raw), "size": len(raw)}
        return {"releaseId": release_id, "url": rel, "sha256": f.digest(raw)}
    jobs, profiles, origins = [], [], {}
    counts = {"accepted": 0, "pending": 0, "failed": 0, "inference_unavailable": 0}
    for job, planned in results.plans.items():
        key = f.fit_key(dict(planned, InferencePrefix="C" + job[1:]))
        entry = results.entries[job]
        item = {"key": key, "plan": {"categoryCodes": [str(x) for x in SCHEMA["factorLevels"][planned["FactorName"]]], "requestedRoles": list(f.ROLES)}}
        if planned["FactorName"] == "wdy_donation":
            item["plan"]["categoryCodes"] = ["2", "3", "4", "5", "6"]
            weekday_entry = results.weekdays.entries[job]
            state = weekday_entry["state"]
            reason = weekday_entry.get("reasonCode")
            if state == "accepted":
                weekday = results.weekdays.selection(job)
                refs = {role: write(job + "-" + role + ".json", value) for role, value in weekday.tables(release_id, key).items()}
                item.update(state="accepted", authority="validated_inference", files=refs)
                profile = weekday.profile(release_id, key)
                profiles.append({"key": key, "state": "available", "profileId": profile["profileId"], "file": write(job + "-profile.json", profile)})
                origins[job] = weekday.origins
        elif entry["state"] in ("pending", "failed"):
            state, reason = entry["state"], entry["reasonCode"]
        else:
            model = results.selection(job)
            reason = model.state()
            state = "inference_unavailable" if reason else "accepted"
            origins[job] = {"executionId": entry["executionId"], "producingVersions": entry["producingVersions"],
                            "nativeModelCodeHash": model.context["identity"]["CodeHash"],
                            "contextSHA256": entry["contextSHA256"], "validationSHA256": entry["validationSHA256"], "conversionSHA256": entry["conversionSHA256"]}
            if state == "accepted":
                refs = {}
                identity_schema = SCHEMA["inference"]["identity"]
                context_schema = {"Character": identity_schema["CharacterColumns"], "Numeric": identity_schema["NumericColumns"]}
                for role in f.ROLES:
                    header, rows, source_sha = model.table("inference", role, identity=model.identity)
                    table = f.compact_table(header, rows, model.identity, context_schema, release_id=release_id, key=key, role=role, source_sha=source_sha)
                    refs[role] = write(job + "-" + role + ".json", table)
                item.update(state="accepted", authority="validated_inference", files=refs)
                profile = model.profile(release_id, key)
                profiles.append({"key": key, "state": "available", "profileId": profile["profileId"], "file": write(job + "-profile.json", profile)})
        if state != "accepted":
            item.update(state=state, reasonCode=reason)
            profiles.append({"key": key, "state": "unavailable", "reasonCode": reason})
        counts[state] += 1
        jobs.append(item)
    manifest = {"schemaVersion": f.RELEASE_SCHEMA, "releaseId": release_id, "datasetKind": "full_cohort",
                "diagnosticOnly": True, "scientificApproved": False, "publicationApproved": False, "jobs": jobs}
    raw = f.encode(manifest)
    (stage / "release.json").write_bytes(raw)
    written["release.json"] = {"sha256": f.digest(raw), "size": len(raw)}
    method_ref = write("methods.json", {"schemaVersion": "transfusion-dashboard/methods-v2", "releaseId": release_id,
                                     "sourceSha256": results.index["methods"]["sha256"], "sections": results.methods})
    reports = results.supplements.write_reports(write, release_id)
    supplement = {"schemaVersion": f.SUPPLEMENTS_SCHEMA, "releaseId": release_id, "coreManifestSha256": f.digest(raw),
                  **{k: manifest[k] for k in ("datasetKind", "diagnosticOnly", "scientificApproved", "publicationApproved")},
                  "reports": reports, "profiles": profiles, "methods": method_ref}
    raw_supp = f.encode(supplement)
    (stage / "supplements.json").write_bytes(raw_supp)
    written["supplements.json"] = {"sha256": f.digest(raw_supp), "size": len(raw_supp)}
    loess = results.supplements.write_loess(write, release_id, manifest, f.digest(raw))
    if loess is not None:
        loess_raw = f.encode(loess)
        (stage / "loess.json").write_bytes(loess_raw)
        written["loess.json"] = {"sha256": f.digest(loess_raw), "size": len(loess_raw)}
    f.require({p.relative_to(stage).as_posix() for p in stage.rglob("*") if p.is_file()} == set(written), "OUTPUT_ALLOWLIST_MISMATCH")
    results.unchanged()
    f.require(source_hashes == {name: f.digest((HERE / name).read_bytes()) for name in source_members}, "ADAPTER_SOURCE_CHANGED")
    record = {"schemaVersion": "transfusion-analysis/results-adapter-receipt-v2", "releaseId": release_id,
              "adapterSourceSHA256": source_hashes, "indexSHA256": index_sha256, "analysisPackageSHA256": results.index["analysisPackageSHA256"],
              "states": counts, "actualProducingVersions": origins,
              "modelProducerVersionAuthority": "REVIEWED_INDEX_ASSERTIONS_NOT_INDEPENDENT_EXECUTION_PROOF",
              "inputFiles": results.used, "outputFiles": written,
              "reportAdapterComplete": True, "loessAdapterComplete": True, "supplementEvidence": results.supplements.evidence, "statisticsRecomputed": False,
              "sampleFallbackPermitted": False, "publicationAuthorized": False}
    receipt.parent.mkdir(parents=True, exist_ok=True)
    with receipt.open("xb") as stream: stream.write(f.encode(record))
    os.rename(stage, output)
    return {"status": "RESULTS_PREVIEW_CREATED", "states": counts, "files": len(written), "reportAdapterComplete": True, "loessAdapterComplete": True}

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--index", default="results.json")
    parser.add_argument("--index-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = normalize(args.input_root, args.index, args.index_sha256, args.output, args.release_id, args.receipt)
    except (f.NormalizationError, OSError, KeyError, TypeError, ValueError, csv.Error):
        print("MODEL_ADAPTER_REJECTED", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

