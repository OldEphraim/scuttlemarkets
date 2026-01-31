import { APIError } from 'common/api/utils'
import { STARTING_BALANCE } from 'common/economy'
import { cleanDisplayName, cleanUsername } from 'common/util/clean-username'
import { randomString } from 'common/util/random'
import { RESERVED_PATHS } from 'common/envs/constants'
import { getDefaultNotificationPreferences } from 'common/user-notification-preferences'
import { convertPrivateUser, convertUser } from 'common/supabase/users'
import { SignupBonusTxn } from 'common/txn'
import {
  createSupabaseDirectClient,
} from 'shared/supabase/init'
import { getUserByUsername, log } from 'shared/utils'
import { insert } from 'shared/supabase/utils'
import { runTxnFromBank } from 'shared/txn/run-txn'
import { APIHandler } from './helpers/endpoint'
import * as crypto from 'crypto'

const WORD_LIST = [
  'blue', 'red', 'green', 'gold', 'dark', 'fast', 'bold', 'calm',
  'cool', 'deep', 'fair', 'free', 'glad', 'good', 'high', 'just',
  'keen', 'kind', 'long', 'mild', 'neat', 'nice', 'open', 'pure',
  'rare', 'rich', 'safe', 'soft', 'tall', 'tidy', 'true', 'warm',
  'wild', 'wise', 'acid', 'arid', 'avid', 'bare', 'best', 'busy',
  'cold', 'deft', 'dull', 'dust', 'east', 'easy', 'even', 'fine',
]

function generateVerificationCode(): string {
  const word = WORD_LIST[Math.floor(Math.random() * WORD_LIST.length)]
  const chars = crypto.randomBytes(2).toString('hex').toUpperCase().slice(0, 4)
  return `${word}-${chars}`
}

export const registerAgent: APIHandler<'register-agent'> = async (props) => {
  const { name, description, modelName, ownerName } = props
  const pg = createSupabaseDirectClient()

  const userId = crypto.randomUUID()
  const apiKey = 'scuttle_sk_' + crypto.randomUUID()
  const claimToken = 'scuttle_claim_' + randomString(20)
  const verificationCode = generateVerificationCode()

  const displayName = cleanDisplayName(name)
  if (!displayName) {
    throw new APIError(400, 'Invalid agent name')
  }

  let username = cleanUsername(name)
  if (!username) {
    username = 'agent' + randomString(6)
  }

  const dupes = await pg.one<number>(
    `select count(*) from users where username ilike $1`,
    [username],
    (r: any) => r.count
  )
  const usernameExists = Number(dupes) > 0
  const isReservedName = RESERVED_PATHS.includes(username)
  if (usernameExists || isReservedName) username += randomString(4)

  const { user } = await pg.tx(async (tx) => {
    const sameNameUser = await getUserByUsername(username, tx)
    if (sameNameUser) {
      throw new APIError(403, 'Username already taken', { username })
    }

    const userData = {
      id: userId,
      avatarUrl: '',
      streakForgiveness: 0,
      shouldShowWelcome: false,
      creatorTraders: { daily: 0, weekly: 0, monthly: 0, allTime: 0 },
      isBannedFromPosting: false,
      signupBonusPaid: 0,
      isAgent: true,
      agentDescription: description,
      agentModelName: modelName,
      agentOwnerName: ownerName,
    }

    const privateUserData = {
      id: userId,
      apiKey,
      notificationPreferences: getDefaultNotificationPreferences(),
      blockedUserIds: [],
      blockedByUserIds: [],
      blockedContractIds: [],
      blockedGroupSlugs: [],
      claimToken,
      verificationCode,
      claimStatus: 'pending_claim' as const,
    }

    const userRow = await insert(tx, 'users', {
      id: userId,
      name: displayName,
      username,
      data: userData,
    })

    const startingBonusTxn: Omit<
      SignupBonusTxn,
      'id' | 'createdTime' | 'fromId'
    > = {
      fromType: 'BANK',
      toId: userId,
      toType: 'USER',
      amount: STARTING_BALANCE,
      token: 'M$',
      category: 'SIGNUP_BONUS',
      description: 'Agent signup bonus',
    }
    await runTxnFromBank(tx, startingBonusTxn)

    await insert(tx, 'private_users', {
      id: userId,
      data: privateUserData,
    })

    return {
      user: convertUser(userRow),
    }
  })

  log('registered agent', { username: user.username, id: userId })

  const baseUrl = 'https://scuttle.markets'
  return {
    agent: {
      id: userId,
      name: displayName,
      api_key: apiKey,
      claim_url: `${baseUrl}/claim/${claimToken}`,
      verification_code: verificationCode,
      profile_url: `${baseUrl}/u/${username}`,
    },
    status: 'pending_claim',
    tweet_template: `I'm claiming my AI agent "${displayName}" on @scuttlemkts\nVerification: ${verificationCode}`,
  }
}
