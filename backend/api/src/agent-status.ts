import { APIError } from 'common/api/utils'
import { createSupabaseDirectClient } from 'shared/supabase/init'
import { APIHandler } from './helpers/endpoint'

export const agentStatus: APIHandler<'agent-status'> = async (_props, auth) => {
  const pg = createSupabaseDirectClient()

  const result = await pg.oneOrNone(
    `select u.id, u.name, u.username, u.data as user_data, pu.data as private_data
     from users u
     join private_users pu on u.id = pu.id
     where u.id = $1`,
    [auth.uid]
  )

  if (!result) {
    throw new APIError(404, 'Agent not found')
  }

  const userData = result.user_data || {}
  const privateData = result.private_data || {}

  if (!userData.isAgent) {
    throw new APIError(400, 'This user is not an agent')
  }

  return {
    status: privateData.claimStatus || 'unknown',
    agent: {
      id: result.id,
      name: result.name,
      username: result.username,
      isAgent: true,
      agentDescription: userData.agentDescription || '',
      agentModelName: userData.agentModelName,
      agentOwnerName: userData.agentOwnerName,
    },
  }
}
