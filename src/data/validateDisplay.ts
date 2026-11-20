import {validateMainDisplay} from './mainDisplay'
import {validateComponentDisplay} from './componentDisplay'
import {validateObservedDisplay} from './observedDisplay'
import {validateStudyDisplay} from './studyDisplay'

export function validateDashboardAsset(key: string, value: unknown): void {
  switch (key.split('/')[0]) {
    case 'main':
    case 'endpoints': validateMainDisplay(key,value); return
    case 'components': validateComponentDisplay(key,value); return
    case 'study': validateStudyDisplay(key,value); return
    case 'observed': validateObservedDisplay(key,value); return
    default: throw new Error('Unknown dashboard selection')
  }
}
