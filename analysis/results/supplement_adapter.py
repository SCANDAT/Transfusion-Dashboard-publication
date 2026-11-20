"""Convert cohort summaries and fitted LOESS grids to dashboard tables."""
from __future__ import annotations
import csv
import hashlib
import io
import itertools
import json
from pathlib import Path
import re
import release_format as f

HERE = Path(__file__).resolve().parent
SCHEMA = json.loads((HERE / "supplement_schema.json").read_text(encoding="utf-8"))
REPORTS = {"R_PREPARATION": ("PREPARATION", "GLOBAL_PREPARATION"),
           **{"R_" + p: ("POPULATION", p) for p in f.POPULATIONS}}
LOESS_ROLES = ("loess_metadata", "loess_status", "loess_support", "loess_predictions", "loess_manifest")
EMPTY_ROLES = ("pipeline_identity", "population_counts", "report_identity", "report_status", "report_unavailable")
AVAILABLE = {"AVAILABLE_EXACT_KNOT", "AVAILABLE_LINEAR_FROM_DIRECT"}
SUPPORT_STAGES = {"GLOBAL_SCALING_SCOPE", "DISPLAY_WINDOW_AVAILABLE_OUTCOME", "POST_BERNOULLI",
                  "POST_EVERY_THIRD", "ACTUAL_NONMISSING_LOESS_INPUT"}

def exact(value, keys, code):
    f.require(isinstance(value, dict) and set(value) == set(keys), code)

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii")

class HashingReader(io.RawIOBase):
    """Hash the original bytes during the single CSV parsing pass."""
    def __init__(self, raw):
        self.raw, self.hasher, self.size = raw, hashlib.sha256(), 0
    def readable(self): return True
    def readinto(self, buffer):
        n = self.raw.readinto(buffer)
        if n:
            self.hasher.update(memoryview(buffer)[:n])
            self.size += n
        return n

class Selection:
    def __init__(self, owner, entry, task):
        self.owner, self.results, self.entry = owner, owner.results, entry
        root = entry["directory"]
        self.context = self.results.bound(root + "/context.json", entry["contextSHA256"], json_file=True)
        validation = self.results.bound(root + "/validation.json", entry["validationSHA256"], json_file=True)
        conversion = self.results.bound(root + "/decimal_csv/conversion.json", entry["conversionSHA256"], json_file=True)
        f.require(self.context.get("task") == task, "SUPPLEMENT_TASK_MISMATCH")
        f.require(validation.get("contextHash") == f.digest(canonical(self.context)), "VALIDATION_CONTEXT_MISMATCH")
        result = validation.get("validation", {})
        f.require(result.get("status") == "VALIDATED", "SUPPLEMENT_VALIDATION_REQUIRED")
        f.require(conversion.get("numericFormat") == "PY_REPR_BINARY64"
                  and conversion.get("validationSha256") == entry["validationSHA256"]
                  and conversion.get("publicReleaseAuthorized") is False, "CONVERSION_BINDING_MISMATCH")
        fields = SCHEMA["ReportContext"] if task == "REPORT" else SCHEMA["LOESS"]["Context"]
        expected = self.context.get("expected", {})
        f.require(set(fields) <= set(expected), "SUPPLEMENT_CONTEXT_MISSING")
        self.expected = {k: expected[k] for k in fields}
        for value in self.expected.values(): owner.text(value)
        identity = self.context.get("identity", {})
        for key in ("RunId", "AnalysisSpecId", "CohortMode", "InputSnapshotId", "CodeHash", "ConfigHash"):
            f.require(expected.get(key) == identity.get(key), "SUPPLEMENT_IDENTITY_MISMATCH")
        f.require(expected["CohortMode"] == "full_cohort"
                  and expected["InputSnapshotId"] == self.results.index["inputSnapshotId"]
                  and expected["DisclosureStatus"] == "PRIVATE_UNREVIEWED", "SUPPLEMENT_COHORT_OR_DISCLOSURE")
        for key in ("RunId", "ExportId"):
            f.require(re.fullmatch(r"[a-f0-9]{32}", expected[key]), "SUPPLEMENT_ID_INVALID")
        for key in ("InputSnapshotId", "CodeHash", "ConfigHash", "ExportCodeHash"):
            f.require(f.HEX.fullmatch(expected[key]), "SUPPLEMENT_HASH_INVALID")
        preparation = task == "REPORT" and entry["JobID"] == "R_PREPARATION"
        if preparation:
            f.require(all(expected[k] == "NOT_APPLICABLE" for k in ("ReportRunId", "ReportCodeHash", "ReportConfigHash")), "PREPARATION_REPORT_IDENTITY")
        else:
            f.require(re.fullmatch(r"[a-f0-9]{32}", expected["ReportRunId"])
                      and f.HEX.fullmatch(expected["ReportCodeHash"])
                      and f.HEX.fullmatch(expected["ReportConfigHash"]), "REPORT_IDENTITY_INVALID")
        if task == "REPORT":
            f.require((expected["Bundle"], expected["PopulationId"]) == REPORTS[entry["JobID"]], "REPORT_POPULATION_MISMATCH")
        else:
            f.require(expected["PopulationId"] == "PRIMARY"
                      and expected["PreparationReceiptHash"] == identity.get("PreparationReceiptHash")
                      and f.HEX.fullmatch(expected["PreparationReceiptHash"]), "LOESS_CONTEXT_MISMATCH")
        analysis_hash = expected["CodeHash"] if preparation else expected["ReportCodeHash"]
        f.require(entry["producingVersions"] == {"analysisSHA256": analysis_hash, "exportSHA256": expected["ExportCodeHash"]},
                  "SUPPLEMENT_PRODUCING_VERSION_MISMATCH")
        known = result.get("inputHashes")
        f.require(isinstance(known, dict) and known, "SUPPLEMENT_INPUT_HASHES_REQUIRED")
        for name, sha in known.items():
            f.require(isinstance(name, str) and re.fullmatch(r"[a-z_]+\.csv", name)
                      and isinstance(sha, str) and f.HEX.fullmatch(sha), "SUPPLEMENT_MEMBER_INVALID")
        self.converted = {}
        for row in conversion.get("files", []):
            exact(row, ("file", "sourceSha256", "decimalSha256"), "CONVERSION_FILE_FIELDS")
            name = row["file"]
            f.require(isinstance(name, str) and name.startswith("csv/") and name[4:] in known
                      and name not in self.converted and row["sourceSha256"] == known[name[4:]]
                      and isinstance(row["decimalSha256"], str) and f.HEX.fullmatch(row["decimalSha256"]), "CONVERSION_SOURCE_MISMATCH")
            self.converted[name] = row
        f.require(set(self.converted) == {"csv/" + name for name in known}, "CONVERSION_INCOMPLETE")
        self.task, self.cache = task, {}
        owner.evidence[entry["JobID"]] = {
            "state": "accepted", "executionId": entry["executionId"],
            "producingVersions": entry["producingVersions"], "expectedContext": self.expected,
            **{k: entry[k] for k in ("contextSHA256", "validationSHA256", "conversionSHA256")},
        }

    def binding(self, role):
        allowed = set(SCHEMA["Reports"]) | {"aggregate_manifest"} if self.task == "REPORT" else set(LOESS_ROLES)
        f.require(role in allowed, "PRIVATE_SUPPLEMENT_ROLE_FORBIDDEN")
        key = "csv/" + role + ".csv"
        f.require(key in self.converted, "SUPPLEMENT_ROLE_MISSING")
        binding = self.converted[key]
        return self.entry["directory"] + "/decimal_csv/" + key, binding["decimalSha256"]

    def table(self, role):
        if role in self.cache: return self.cache[role]
        member, sha = self.binding(role)
        raw = self.results.bound(member, sha)
        definition = (SCHEMA["ReportManifest"] if role == "aggregate_manifest" else SCHEMA["Reports"][role]) if self.task == "REPORT" else SCHEMA["LOESS"]["Schemas"][role]
        columns, numeric = definition["Columns"], set(definition["NumericColumns"])
        try: header = next(csv.reader(io.StringIO(raw.decode("utf-8-sig"), newline=""), strict=True))
        except (StopIteration, UnicodeError, csv.Error): raise f.NormalizationError("SUPPLEMENT_HEADER_INVALID") from None
        f.require(len(header) == len(columns) and set(header) == set(columns), "SUPPLEMENT_SCHEMA_MISMATCH")
        rows = f.parse_csv(raw, header, numeric)
        for row in rows:
            for key in columns:
                if key not in numeric: self.owner.text(row[key])
            if self.task == "REPORT" or role == "loess_metadata":
                f.require(all(row.get(k) == value for k, value in self.expected.items()), "SUPPLEMENT_ROW_CONTEXT_MISMATCH")
        self.cache[role] = columns, rows, sha
        return self.cache[role]

    def manifest(self, role, roles):
        _, rows, _ = self.table(role)
        f.require(len(rows) == len(roles) and {row["Role"] for row in rows} == set(roles), "SUPPLEMENT_MANIFEST_ROLES")
        result = {}
        for row in rows:
            name = row["Role"]
            f.require(row["FileName"] == name + ".csv" and row["NumericFormat"] == "PY_REPR_BINARY64"
                      and row["TextEncoding"] == "UTF-8" and row["ExportStatus"] == "EXPORTED_LOCAL_ONLY"
                      and row["RowCount"] is not None and row["RowCount"] >= 0
                      and row["RowCount"].is_integer() and row["ColumnCount"] is not None
                      and row["ColumnCount"].is_integer(), "SUPPLEMENT_MANIFEST_INVALID")
            if self.task == "REPORT": f.require(row["Protocol"] == "RBC_AGGREGATE_REPORTS_V2", "REPORT_PROTOCOL")
            else:
                f.require(row["Protocol"] == "RBC_LOESS_REPORT_V1"
                          and row["LoessReportId"] == self.expected["ReportRunId"]
                          and row["ExportId"] == self.expected["ExportId"]
                          and row["ExportCodeHash"] == self.expected["ExportCodeHash"], "LOESS_MANIFEST_IDENTITY")
            result[name] = row
        return result

    @staticmethod
    def dimensions(manifest, role, columns, rows):
        f.require(manifest[role]["RowCount"] == len(rows) and manifest[role]["ColumnCount"] == len(columns), "SUPPLEMENT_MANIFEST_DIMENSIONS")

class Supplements:
    def __init__(self, results, text):
        self.results, self.text, self.evidence = results, text, {}
        entries = results.index["reports"]
        f.require(isinstance(entries, list) and len(entries) == 4, "FOUR_REPORT_STATES_REQUIRED")
        self.reports = {}
        for entry in entries:
            self.check_entry(entry, set(REPORTS))
            f.require(entry["JobID"] not in self.reports, "DUPLICATE_REPORT")
            self.reports[entry["JobID"]] = entry
        f.require(set(self.reports) == set(REPORTS), "FOUR_REPORT_STATES_REQUIRED")
        self.loess = results.index["loess"]
        self.check_entry(self.loess, {"L_PRIMARY"})

    def check_entry(self, entry, allowed):
        f.require(isinstance(entry, dict) and entry.get("JobID") in allowed
                  and entry.get("state") in {"accepted", "pending", "failed", "inference_unavailable"}, "SUPPLEMENT_ENTRY_INVALID")
        if entry["state"] == "accepted":
            exact(entry, ("JobID", "state", "directory", "contextSHA256", "validationSHA256", "conversionSHA256", "executionId", "producingVersions"), "SUPPLEMENT_ENTRY_FIELDS")
            for field in ("contextSHA256", "validationSHA256", "conversionSHA256"):
                f.require(isinstance(entry[field], str) and f.HEX.fullmatch(entry[field]), "SUPPLEMENT_BINDING_INVALID")
            f.relative_path(self.results.root, entry["directory"])
            f.require(isinstance(entry["executionId"], str) and f.TOKEN.fullmatch(entry["executionId"]), "SUPPLEMENT_EXECUTION_INVALID")
            exact(entry["producingVersions"], ("analysisSHA256", "exportSHA256"), "SUPPLEMENT_VERSIONS_REQUIRED")
            for sha in entry["producingVersions"].values(): f.require(isinstance(sha, str) and f.HEX.fullmatch(sha), "SUPPLEMENT_VERSION_INVALID")
        else:
            exact(entry, ("JobID", "state", "reasonCode"), "SUPPLEMENT_STATUS_FIELDS")
            f.require(isinstance(entry["reasonCode"], str) and f.REASON.fullmatch(entry["reasonCode"]), "SUPPLEMENT_REASON_INVALID")

    def write_reports(self, write, release_id):
        output = []
        for job, (bundle, population) in REPORTS.items():
            entry = self.reports[job]
            key = {"scope": "preparation", "population": None} if bundle == "PREPARATION" else {"scope": "population", "population": population}
            if entry["state"] != "accepted":
                output.append({"key": key, "state": entry["state"], "reasonCode": entry["reasonCode"]})
                self.evidence[job] = {"state": entry["state"], "reasonCode": entry["reasonCode"]}
                continue
            selected = Selection(self, entry, "REPORT")
            empty = False
            if bundle == "POPULATION":
                _, status, _ = selected.table("report_status")
                f.require(len(status) == 1 and status[0]["Status"] in {"COMPLETE", "EMPTY_POPULATION"}, "REPORT_STATUS_INVALID")
                empty = status[0]["Status"] == "EMPTY_POPULATION"
                _, identity, _ = selected.table("report_identity")
                f.require(len(identity) == 1 and identity[0]["ReportStatus"] == "REPORTS_COMPLETE", "REPORT_IDENTITY_STATUS")
            roles = list(EMPTY_ROLES) if empty else SCHEMA["PreparationRoles" if bundle == "PREPARATION" else "PopulationRoles"]
            f.require(set(selected.converted) == {"csv/" + name + ".csv" for name in roles + ["aggregate_manifest"]}, "REPORT_ROLE_SET")
            manifest = selected.manifest("aggregate_manifest", roles)
            files = {}
            for role in roles:
                columns, rows, sha = selected.table(role)
                selected.dimensions(manifest, role, columns, rows)
                if not empty:
                    from weekday_adapter import project_report
                    rows, omitted = project_report(role, rows)
                    if omitted:
                        self.evidence[job].setdefault("weekendPhysiologyRowsOmitted", {})[role] = omitted
                    table = {"schemaVersion": f.REPORT_TABLE_SCHEMA, "releaseId": release_id,
                             "reportKey": key, "role": role, "sourceSha256": sha,
                             **f.pack_columns(columns, rows, selected.expected)}
                    files[role] = write(job + "-" + role + ".json", table)
            if empty:
                _, counts, _ = selected.table("population_counts")
                matching = [r for r in counts if r["ReportedPopulationId"] == population]
                f.require(len(matching) == 1 and matching[0]["NEvents"] == 0 and matching[0]["NPersons"] == 0, "EMPTY_POPULATION_COUNTS")
                self.evidence[job].update(normalizedState="inference_unavailable", reasonCode="EMPTY_POPULATION")
                output.append({"key": key, "state": "inference_unavailable", "reasonCode": "EMPTY_POPULATION"})
            else: output.append({"key": key, "state": "accepted", "expectedContext": selected.expected, "files": files})
        return output

    def write_loess(self, write, release_id, core, core_sha):
        if self.loess["state"] != "accepted":
            self.evidence["L_PRIMARY"] = {"state": self.loess["state"], "reasonCode": self.loess["reasonCode"]}
            return None
        selected = Selection(self, self.loess, "LOESS")
        f.require(set(selected.converted) == {"csv/" + role + ".csv" for role in LOESS_ROLES}, "LOESS_ROLE_SET")
        roles = list(LOESS_ROLES[:-1])
        manifest = selected.manifest("loess_manifest", roles)
        const = SCHEMA["LOESS"]["Constants"]
        columns, metadata, _ = selected.table("loess_metadata")
        selected.dimensions(manifest, "loess_metadata", columns, metadata)
        f.require(len(metadata) == 7 and {r["VitalCode"] for r in metadata} == set(f.OUTCOMES), "LOESS_METADATA_UNIVERSE")
        for row in metadata:
            f.require(row["LoessReportId"] == selected.expected["ReportRunId"] and all(row[k] == value for k, value in const.items()), "LOESS_METHOD_CHANGED")
        columns, rows, _ = selected.table("loess_status")
        selected.dimensions(manifest, "loess_status", columns, rows)
        statuses = {}
        for row in rows:
            key = row["VitalCode"], row["SpanPercent"]
            f.require(key not in statuses and row["LoessReportId"] == selected.expected["ReportRunId"]
                      and row["FitStatus"] in SCHEMA["LOESS"]["FitStatuses"]
                      and row["PointStatusPolicy"] == "EXPLICIT_GRID_STATUS_NO_EXTRAPOLATION", "LOESS_STATUS_INVALID")
            statuses[key] = row["FitStatus"]
        f.require(set(statuses) == set(itertools.product(f.OUTCOMES, range(10, 91))), "LOESS_STATUS_UNIVERSE")
        columns, rows, _ = selected.table("loess_support")
        selected.dimensions(manifest, "loess_support", columns, rows)
        f.require(len(rows) == 35 and {(r["VitalCode"], r["SupportStage"]) for r in rows} == set(itertools.product(f.OUTCOMES, SUPPORT_STAGES)), "LOESS_SUPPORT_UNIVERSE")
        for row in rows:
            f.require(row["LoessReportId"] == selected.expected["ReportRunId"] and row["DisclosureStatus"] == "PRIVATE_UNREVIEWED"
                      and row["OverlapSemantics"] == "PERSON_EVENT_COUNTS_NONADDITIVE", "LOESS_SUPPORT_IDENTITY")
        entries = self.series(selected, manifest, statuses, write, release_id)
        return {"schemaVersion": "transfusion-dashboard/loess-v1", "releaseId": release_id,
                "coreManifestSha256": core_sha,
                **{k: core[k] for k in ("datasetKind", "diagnosticOnly", "scientificApproved", "publicationApproved")},
                "population": "PRIMARY", "methodId": const["MethodId"], "defaultSpanPercent": 30, "series": entries}

    def series(self, selected, manifest, statuses, write, release_id):
        member, sha = selected.binding("loess_predictions")
        path = f.relative_path(self.results.root, member)
        definition = SCHEMA["LOESS"]["Schemas"]["loess_predictions"]
        columns, numeric = definition["Columns"], set(definition["NumericColumns"])
        pending, completed, entries, count = {}, set(), [], 0
        with path.open("rb") as raw:
            hashed = HashingReader(raw)
            with io.TextIOWrapper(io.BufferedReader(hashed), encoding="utf-8-sig", newline="") as stream:
                reader = csv.reader(stream, strict=True)
                try: header = next(reader)
                except StopIteration: raise f.NormalizationError("LOESS_HEADER_MISSING") from None
                f.require(len(header) == len(columns) and set(header) == set(columns), "LOESS_SCHEMA_MISMATCH")
                for cells in reader:
                    f.require(len(cells) == len(header), "LOESS_ROW_WIDTH")
                    row = {k: f.typed_number(v) if k in numeric else v for k, v in zip(header, cells)}
                    key, grid, point = check_point(row, statuses, selected.expected["ReportRunId"])
                    f.require(key not in completed, "LOESS_DUPLICATE_SERIES")
                    points = pending.setdefault(key, {})
                    f.require(grid not in points, "LOESS_DUPLICATE_GRID_POINT")
                    points[grid] = point
                    count += 1
                    if len(points) == 1441:
                        outcome, span, scale = key
                        rows = [points[i] for i in range(1, 1442)]
                        fit = statuses[(outcome, span)]
                        table = {"schemaVersion": "transfusion-dashboard/loess-series-v2", "releaseId": release_id,
                                 "outcome": outcome, "spanPercent": span, "scale": scale, "sourceSha256": sha,
                                 "fitStatus": fit, "unit": "NATIVE" if scale == "native" else "SD",
                                 "unitStatus": "SOURCE_UNIT_UNCONFIRMED" if scale == "native" else "STANDARDIZED_GLOBAL_SD",
                                 "intervalStatus": "NOT_EXPORTED_DESCRIPTIVE", "methodAdoptionStatus": "DIRECT_DEGREE2_LOESS",
                                 "columns": ["TimeFromTransfusion", "Estimate", "PointStatus", "SupportStatus"], "rows": rows}
                        ref = write("loess-" + outcome + "-" + str(span) + "-" + scale + ".json", table)
                        entries.append({"outcome": outcome, "spanPercent": span, "scale": scale, "fitStatus": fit, "file": ref})
                        completed.add(key)
                        del pending[key]
        f.require(hashed.hasher.hexdigest() == sha, "LOESS_BOUND_HASH_MISMATCH")
        self.results.used[member] = {"sha256": sha, "size": hashed.size}
        f.require(not pending and completed == set(itertools.product(f.OUTCOMES, range(10, 91), ("native", "standardized"))), "LOESS_SERIES_INCOMPLETE")
        f.require(count == 1634094 and manifest["loess_predictions"]["RowCount"] == count
                  and manifest["loess_predictions"]["ColumnCount"] == len(columns), "LOESS_PREDICTION_DIMENSIONS")
        return sorted(entries, key=lambda r: (f.OUTCOMES.index(r["outcome"]), r["spanPercent"], r["scale"]))

def check_point(row, statuses, report_id):
    outcome, span, grid = row["VitalCode"], row["SpanPercent"], row["GridPointId"]
    f.require(outcome in f.OUTCOMES and span is not None and span.is_integer() and 10 <= span <= 90
              and grid is not None and grid.is_integer() and 1 <= grid <= 1441, "LOESS_POINT_IDENTITY")
    f.require(row["LoessReportId"] == report_id and row["TimeFromTransfusion"] == grid - 721, "LOESS_POINT_TIME")
    for key in ("MethodId", "GridId", "IntervalStatus", "MethodAdoptionStatus"):
        f.require(row[key] == SCHEMA["LOESS"]["Constants"][key], "LOESS_POINT_METHOD")
    f.require(row["DisclosureStatus"] == "PRIVATE_UNREVIEWED" and row["ValueScale"] in {"NATIVE", "Z_SCORE"}, "LOESS_POINT_POLICY")
    native = row["ValueScale"] == "NATIVE"
    f.require(row["Unit"] == ("NATIVE" if native else "SD")
              and row["UnitStatus"] == ("SOURCE_UNIT_UNCONFIRMED" if native else "STANDARDIZED_GLOBAL_SD"), "LOESS_POINT_UNITS")
    status, support, estimate = row["PointStatus"], row["SupportStatus"], row["Estimate"]
    f.require(status in SCHEMA["LOESS"]["PointStatuses"] and (status in AVAILABLE) == (estimate is not None), "LOESS_POINT_AVAILABILITY")
    fit = statuses[(outcome, span)]
    if fit != "DIRECT_COMPLETED":
        f.require(status == fit and support == ("INSUFFICIENT_FITTING_SUPPORT" if fit == "INSUFFICIENT_SUPPORT" else "NO_RETAINED_INPUT"), "LOESS_UNAVAILABLE_FIT")
    else:
        f.require(status in AVAILABLE | {"FIT_UNAVAILABLE", "NATIVE_TRANSFORM_UNAVAILABLE", "OUTSIDE_RETAINED_SUPPORT"}, "LOESS_POINT_STATUS")
        f.require(support == ("OUTSIDE_RETAINED_SUPPORT" if status == "OUTSIDE_RETAINED_SUPPORT" else "WITHIN_RETAINED_RANGE"), "LOESS_POINT_SUPPORT")
        f.require(status != "NATIVE_TRANSFORM_UNAVAILABLE" or native, "LOESS_NATIVE_TRANSFORM_STATUS")
    return (outcome, int(span), "native" if native else "standardized"), int(grid), [row["TimeFromTransfusion"], estimate, status, support]

