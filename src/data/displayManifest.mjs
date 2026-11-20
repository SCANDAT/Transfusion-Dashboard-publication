const populations = ['PRIMARY','FIRST_EVENT','NO_FOLLOWING_UNIT_12H']
const models = ['BASE','FULL']
const outcomes = ['ARTm','ARTs','ARTd','HR','FIO2','SPO2','VE']
const factors = ['DonorHb_Cat','Storage_Cat','DonorSex','DonorParity_Female','wdy_donation']
const hash = /^[a-f0-9]{64}$/

export function displayKeys() {
  const keys = []
  for (const model of models) {
    keys.push('endpoints/' + model)
    for (const population of populations) for (const outcome of outcomes) {
      for (const scale of ['levels','changes']) keys.push(['main',population,model,outcome,scale].join('/'))
      for (const factor of factors) keys.push(['components',population,model,factor,outcome].join('/'))
    }
  }
  for (const outcome of outcomes) for (const scale of ['native','standardized']) {
    keys.push(['observed',outcome,scale].join('/'))
  }
  for (const population of populations) keys.push('study/' + population)
  return keys.sort()
}

export function allStudyPopulationsSelected(isSelected) {
  return populations.every(population => isSelected('study/' + population))
}

export function validateStudyScope(value, manifest) {
  const complete = value?.saps?.allPopulationsComplete
  const allSelected = allStudyPopulationsSelected(key => Boolean(manifest.assets[key]))
  if (allSelected ? typeof complete !== 'boolean' : complete !== null) {
    throw new Error('SAPS completeness assessment does not match the selected Study populations')
  }
}

export function validateDisplayManifest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).sort().join('|') !== 'assets|releaseId|schemaVersion' ||
      value.schemaVersion !== 'transfusion-dashboard/display-v2' ||
      typeof value.releaseId !== 'string' || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value.releaseId) ||
      value.releaseId.length > 64 || !value.assets || typeof value.assets !== 'object' ||
      Array.isArray(value.assets)) throw new Error('Invalid display manifest')
  const keys = displayKeys()
  const actual = Object.keys(value.assets).sort()
  if (actual.length !== keys.length || keys.some((key,index) => key !== actual[index])) {
    throw new Error('Incomplete or unexpected dashboard selection')
  }
  for (const key of keys) {
    const digest = value.assets[key]
    if (digest !== null && !(typeof digest === 'string' && hash.test(digest))) {
      throw new Error('Invalid dashboard result digest')
    }
  }
  return value
}

// Match the bytes emitted by the display writer. Duplicate JSON keys and
// trailing text cannot be hidden by a permissive JSON parser.
export function parseDisplayJson(text) {
  const value = JSON.parse(text)
  if (JSON.stringify(value) + '\n' !== text) throw new Error('Invalid display JSON encoding')
  return value
}
