#!/bin/bash

tmp=./_tmp
while [ $# -gt 0 ]; do
  if [[ $1 = '--inspect' ]]; then
    inspect=1
  elif [[ $1 = '--dry-run' ]]; then
    dryrun=1
  else
    types=$1
    shift 1
    corpus=$1
  fi
  shift 1
done
if [[ $types = '' || $corpus = '' ]]; then
  echo "(C) Copyright IBM Corp. 2023 All Rights Reserved."
  echo "Convert WKS types/subtypes to be used for Watson Discovery V2"
  echo "Usage : `basename $0` [--inspect|--dry-run] types-json corpus-zip"
  echo "  Step 1: Use --inspect to see what types/subtypes exist"
  echo "  Step 2: Optionally, prepare type-map.json if you want to arrange subtypes"
  echo "  Step 3: Use --dry-run to check how conversion will be performed"
  echo "  Step 4: Run it without --dry-run to perform conversion"
  echo "Requirements : Node.js v14 or above, zip, unzip"
  exit 1;
fi
if [ ! -f $types ]; then
  echo $types not found
  exit
fi
if [ ! -f $corpus ]; then
  echo $corpus not found
  exit
fi
typesOut=$(echo $types | sed 's/.json/-converted.json/')
corpusOut=$(echo $corpus | sed 's/.zip/-converted.zip/')
if [[ $inspect != 1 && $dryrun != 1 ]]; then
  if [ ! -d $tmp ]; then
    mkdir $tmp
    (cd $tmp; unzip -q ../$corpus)
  fi
fi

node - <<EOF
const _types = '$types';
const _corpus = '$corpus';
const _inspect = '$inspect';
const _dryrun = '$dryrun';
const _typesOut = '$typesOut';
const _corpusOut = '$corpusOut';
const _tmp = '$tmp';

const fs = require('fs');
const crypto = require('crypto');

const typeMapFile = './type-map.json';
const templateFile = './type-map.json.template';
let map = {};
let outputTypes;
let nDocs = 0;
let nMentions = 0;
let nDropped = 0;
let nTypes = 0;

function print(s, _verbose) {
  if (_verbose) {
    console.log(s);
  }
}

function init() {
  if (fs.existsSync(typeMapFile)) {
    map = JSON.parse(fs.readFileSync(typeMapFile));
  }

  // get all possible flat types
  const data = JSON.parse(fs.readFileSync(_types));
  const allFlatTypes = {};
  data.entityTypes.forEach((type, i) => {
    if (type.sireProp.subtypes) {
      type.sireProp.subtypes.forEach(subtype => {
        allFlatTypes[type.label + '_' + subtype] = 1;
      });
    }
  });
  // validate type-map.json
  for (let key in map) {
    if (map[key] === key) { // key and value are the same, delete it
      delete map[key];
      continue;
    }
    if (map[key] && map[map[key]] === null) { // destination is null
      console.log('Invalid type-map.json. (Check ' + map[key] + ')');
      process.exit(1);
    } else if (map[key] && map[map[key]] === key) { // cyclic mapping
      console.log('Invalid type-map.json. (Check ' + map[key] + ')');
      process.exit(1);
    }
  }
}

function inspect() {
  const data = JSON.parse(fs.readFileSync(_types));
  data.entityTypes.forEach((type, i) => {
    console.log((i + 1) + ' ' + type.label);
    console.log('  ', type.sireProp.subtypes);
  });
}

function getOutputTypes(verbose) {
  const puts = (s) => print(s, verbose);
  const data = JSON.parse(fs.readFileSync(_types));
  const allTypes = {};
  data.entityTypes.forEach((type, i) => {
    if (type.sireProp.subtypes && type.sireProp.subtypes.length > 0) {
      const subtypes = type.sireProp.subtypes.slice();
      subtypes.unshift('NONE');
      puts((i + 1) + ' ' + type.label + ' =>');
      subtypes.forEach(subtype => {
        const typeName = type.label + '_' + subtype;
        if (map[typeName] !== undefined) {
          puts('    ' + typeName + ' => ' + map[typeName]);
          if (map[typeName]) {
            allTypes[map[typeName]] = 1;
          }
        } else {
          puts('    ' + typeName);
          allTypes[typeName] = 1;
        }
      });
    } else { // no subtypes found.
      if (map[type.label] !== undefined) {
        if (map[type.label]) {
          puts((i + 1) + ' ' + type.label + ' => ' + map[type.label] + ' (no subtypes, rename)');
          allTypes[map[type.label]] = 1;
        } else {
          puts((i + 1) + ' ' + type.label + ' (no subtypes, discard)');
        }
      } else { // no map. leave the type name as it is
        puts((i + 1) + ' ' + type.label + ' (no subtypes)');
        allTypes[type.label] = 1;
      }
    }
  });
  puts('\nTypes to be produced:');
  const keys = Object.keys(allTypes);
  keys.forEach((key, i) => {
    puts((i + 1) + ': ' + key);
  });
  nTypes = keys.length;
  return keys;
}

function generateMapTemplate() {
  const obj = outputTypes.reduce((o, c, i) => { o[c] = c; return o; }, {});
  fs.writeFileSync(templateFile, JSON.stringify(obj, null, 2), { encoding:'utf8', flag:'w' });
  console.log('\nGenerated ' + templateFile);
}

function dryrun() {
  outputTypes = getOutputTypes(1);
  if (!fs.existsSync(typeMapFile)) {
    // Generate template only when typeMapFile does not exist
    generateMapTemplate();
  }
}

function convertTypes() {
  const verbose = 0;
  const puts = (s) => print(s, verbose);

  // Flatten all subtypes
  puts('\nFlatten all subtypes:');
  const data = JSON.parse(fs.readFileSync(_types));
  for (let i = data.entityTypes.length - 1; i >= 0; i--) {
    const type = data.entityTypes[i];
    if (type.sireProp.subtypes && type.sireProp.subtypes.length > 0) {
      puts((i + 1) + ' ' + type.label + ' =>');
      puts('    ' + type.label + '_NONE');
      type.sireProp.subtypes.forEach((subtype, j) => {
        const newType = JSON.parse(JSON.stringify(type));
        const id = type.id;
        newType.id = crypto.randomUUID();
        for (let k = 0; k < newType.sireProp.roles.length; k++) {
          if (newType.sireProp.roles[k] === id) {
            newType.sireProp.roles[k] = newType.id;
          }
        }
        const typeName = type.label + '_' + subtype;
        newType.label = typeName;
        puts('    ' + newType.label);
        newType.modifiedDate = new Date().getTime();
        newType.sireProp.subtypes = null;
        data.entityTypes.splice(i + j + 1, 0, newType);
      });
      type.label += '_NONE';
      type.sireProp.subtypes = null;
    } else { // no subtypes found. leave the type name as it is
      puts((i + 1) + ' ' + type.label + ' (no subtypes)');
    }
  }

  // Rename type names
  for (let i = 0; i < data.entityTypes.length; i++) {
    const type = data.entityTypes[i];
    const targetName = map[type.label];
    if (targetName && !data.entityTypes.find(type => type.label === targetName)) {
      // The target is unknown type name, which means renaming the type
      puts(type.label + ' => ' + targetName + ' (rename)');
      type.label = targetName;
    }
  }

  // Filter out unused types
  data.entityTypes = data.entityTypes.filter(type => outputTypes.includes(type.label));
  fs.writeFileSync(_typesOut, JSON.stringify(data, null, 2), { encoding:'utf8', flag:'w' });
  console.log('Flattened type system saved as ' + _typesOut);
}

function convertCorpus(file) {
  const verbose = 0;
  const puts = (s) => print(s, verbose);
  const data = JSON.parse(fs.readFileSync(file));
  if (data.mentions.length === 0) {
    return;
  }
  nDocs++;
  puts('Converting ' + data.id);
  data.mentions.forEach(mention => {
    let typeName;
    if (map[mention.type]) { // map for the original type name exists, renaming
      typeName = mention.type;
    } else {
      typeName = mention.type + '_' + mention.properties.SIRE_ENTITY_SUBTYPE;
    }
    if (map[typeName]) { // merge or rename
      puts('  ' + mention.type + ' => ' + map[typeName] + ' (merge or rename)');
      mention.type = map[typeName];
      mention.properties.SIRE_ENTITY_SUBTYPE = 'NONE';
    } else if (!outputTypes.includes(typeName)) { // no subtypes, just leave it
      puts('  ' + mention.type + ' (skip)');
    } else { // flatten
      puts('  ' + mention.type + ' => ' + typeName + ' (flatten)');
      mention.type = typeName;
      mention.properties.SIRE_ENTITY_SUBTYPE = 'NONE';
    }
  });
  const nPrev = data.mentions.length;
  data.mentions = data.mentions.filter(mention => outputTypes.includes(mention.type));
  nMentions += data.mentions.length;
  nDropped += nPrev - data.mentions.length;
  fs.writeFileSync(file, JSON.stringify(data, null, 2), { encoding:'utf8', flag:'w' });
}

function run() {
  outputTypes = getOutputTypes(1);
  convertTypes();
  fs.readdirSync(_tmp + '/gt').forEach(file => {
    if (file.match(/\.json$/)) {
      convertCorpus(_tmp + '/gt/' + file);
    }
  });
  console.log('\nTotal ' + nMentions + ' mentions in ' + nDocs + ' documents were converted to new types');
  if (nDropped > 0) {
    console.log(nDropped + ' mentions were dropped');
  }
  console.log('Now there are ' + nTypes + ' top-level entity types in total');
}

init();
if (_inspect) {
  inspect();
  process.exit(2);
} else if (_dryrun) {
  dryrun();
  process.exit(2);
} else {
  run();
}
EOF

ret=$?
if [[ $ret = 0 ]]; then
  (cd $tmp; zip -r -q ../t.zip .)
  mv t.zip $corpusOut
  echo Flattened corpus saved as $corpusOut
elif [[ $ret = 2 ]]; then
  :
else
  echo failed
fi
rm -rf $tmp
