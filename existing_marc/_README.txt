Put existing MARC files here.
Only .mrc files will be picked up by the script.

Existing MARC files means...
 - The MARC files containing the records that make up the earlier/previous set of records --- the set against which you want to compare your incoming records.

If your config for a given script run includes:
  use existing record set: true
Then you must have at least one .mrc file in this folder.
If that setting is false, this folder can be empty when you run the script.
