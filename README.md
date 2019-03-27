# MARC Record Set Wrangler
**Running on a networked drive may be very slow. For best performance, run on your own workstation.**

Based on options you can set at the institution, workflow, or collection level, this tool allows you to do things like:

- Clean up the ID field(s) in incoming records
  - You specify which find/replaces will be done on IDs
- Add specified prefixes or suffixes to ID (001, 019, 035) values in incoming records
- Check incoming records for whether language of cataloging matches your configured language(s)
- Check incoming records for lack of standard fields/coding identifying online/e-resource format
- Write warnings to specified MARC field(s) in affected records and/or to a log.csv file
- Determine whether incoming records will overlay records in previous set
  - Match on just main ID (001/035$a value) OR on merged record IDs (019$a/035$z values)
  - Optionally add a MARC field to incoming records specifying which field the match is made on (main or merge)
- Manipulate the order of subfields in 019 to make sure overlay/match point is first
- Determine whether incoming records that will overlay have actually changed or not
  - Fields/subfields to ignore in this comparison can be flexibly specified
- Split incoming records into separate files based on comparison with previous file
  - New and changed records can be written to separate files
  - Overlaying records that haven't changed can be ignored (not written out at all)
- Generate a deletes file from the previous record set
  - This will contain any records from the previous set that will not be overlaid by records in the incoming set
  - Your specified prefixes/suffixes will be added to specified IDs in delete file
- Determine whether **authority controlled heading fields** in incoming records have changed
  - Fields to be treated as authority controlled headings can be flexibly specified
  - You specify a MARC field to be added to incoming records where the headings have changed
- Decide whether a record will be put under authority control based on its LDR/17 Encoding Level value
  - You specify whether each Encoding Level value should be under authority control or not
  - You specify what should be added to each incoming record to indicate whether it should be under authority control or not
- Add specified MARC field(s) to all incoming records
  - Set at the workflow or collection level... or both

For more information about configuring and using this tool:
- See this [project's wiki](https://github.com/UNC-Libraries/MARC-record-set-wrangler/wiki)
