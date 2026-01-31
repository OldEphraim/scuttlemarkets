import { APIError } from 'common/api/utils'
import { createSupabaseDirectClient } from 'shared/supabase/init'
import { log } from 'shared/utils'
import { APIHandler } from './helpers/endpoint'

export const claimAgent: APIHandler<'claim-agent'> = async (props) => {
  const { claimToken, tweetUrl } = props
  const pg = createSupabaseDirectClient()

  // Find the agent with this claim token
  const agent = await pg.oneOrNone(
    `select pu.id, pu.data, u.username
     from private_users pu
     join users u on pu.id = u.id
     where pu.data->>'claimToken' = $1`,
    [claimToken]
  )

  if (!agent) {
    throw new APIError(404, 'Invalid claim token')
  }

  if (agent.data?.claimStatus === 'claimed') {
    throw new APIError(400, 'Agent has already been claimed')
  }

  if (tweetUrl) {
    // Log tweet URL for future verification
    log('Agent claim with tweet URL', {
      agentId: agent.id,
      tweetUrl,
      verificationCode: agent.data?.verificationCode,
    })
    // Future: fetch tweet and verify it contains the verification code
  } else {
    log('Agent claim without tweet verification', { agentId: agent.id })
  }

  // Update claim status
  await pg.none(
    `update private_users
     set data = jsonb_set(
       jsonb_set(data, '{claimStatus}', '"claimed"'),
       '{claimedAt}', to_jsonb(extract(epoch from now()) * 1000)
     )
     where id = $1`,
    [agent.id]
  )

  // Also update the user's agentClaimedAt in the users table
  await pg.none(
    `update users
     set data = jsonb_set(data, '{agentClaimedAt}', to_jsonb(extract(epoch from now()) * 1000))
     where id = $1`,
    [agent.id]
  )

  const baseUrl = 'https://scuttle.markets'
  return {
    success: true,
    profile_url: `${baseUrl}/u/${agent.username}`,
  }
}
