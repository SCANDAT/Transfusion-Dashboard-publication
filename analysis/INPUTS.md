# Input tables

The analysis reads three SAS tables from a restricted input directory. Their SAS member names are set in the local configuration. The identifiers link a person, an admission, a transfusion event and the individual units given at that event. Keep these tables and the person-level outputs in the authorized analysis environment.

## Measurements and index transfusions

| Variables | SAS type | Use |
| --- | --- | --- |
| `StudyID`, `PatientID` | Numeric | Person and recorded clinical/admission identifiers. The admission history resolves their relationship. |
| `TransDt`, `Datetime` | Numeric | Transfusion start and measurement time, in SAS datetime units. |
| `Value` | Numeric | Recorded outcome value. The study applied no additional physiological artifact thresholds. |
| `AdmissionTime`, `DischargeTime` | Numeric | Recorded admission boundaries as SAS datetimes. |
| `Age` | Numeric | Recipient age. |
| `Sex`, `WardName`, `Abbreviation` | Character | Recipient sex, ward and outcome channel. |
| `SAPS_3` | Character | Recorded severity score. The descriptive analysis parses the field and distinguishes nonnumeric entries from missing values. |
| `Crystalloid_1`, `Crystalloid_24`, `Pressors_1`, `Pressors_24` | Numeric | Crystalloid and noradrenaline summaries for 1 and 24 hours, precomputed in the supplied extract. |
| `Sedatives_1`, `Sedatives_24` | Numeric | Sedative/analgesic summaries for 1 and 24 hours, precomputed in the supplied extract and used to derive indicators. |

Treatment windows are relative to each measurement. The underlying source documentation only partially specified their units and calculation rules. Outcome-channel mappings and category rules are defined in the SAS code.

## Transfused red cell units

| Variables | SAS type | Use |
| --- | --- | --- |
| `StudyID`, `Poolnum` | Numeric | Person and physical unit identifiers. |
| `TransDt`, `TransDate` | Numeric | Recorded transfusion datetime and date. |
| `XProdType` | Character | Component type used to select red cell units. |
| `DonDate` | Numeric | Donation timestamp, interpreted as a SAS datetime. |
| `Storage`, `DonorHb`, `DonorSex`, `DonorParity` | Numeric | Recorded storage duration, donor haemoglobin, sex and parity used for component analyses. |

Eligibility and sensitivity analyses require transfusion history before and after index events. The preparation code groups simultaneous units and checks that the category used in a component analysis is defined consistently across them. Donor parity comes from the recorded binary field and is analyzed among female donors.

## Admission history

| Variables | SAS type | Use |
| --- | --- | --- |
| `StudyID`, `PatientID` | Numeric | Person and recorded clinical/admission identifiers. |
| `AdmissionTime`, `DischargeTime` | Character | Recorded boundaries parsed to SAS datetimes during preparation. |

All three tables must use consistent identifiers and the same time basis. Admission history stores its boundaries as character values, while the measurement table uses numeric datetimes. `sas/01_cohort.sas` defines parsing, boundary inclusion, ambiguous linkage and invalid histories. The sensitivity analysis for subsequent units applies to the recorded extraction period and uses an exclusive end boundary.

These input definitions include neither diagnosis codes nor a verified mapping from ward to hospital. Diagnosis and hospital summaries are unavailable from these tables.
