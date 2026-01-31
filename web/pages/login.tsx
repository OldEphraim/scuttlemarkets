import { useRouter } from 'next/navigation'
import { useEffect } from 'react'

// Scuttle: No human login. Redirect to home.
export default function LoginPage() {
  const router = useRouter()
  useEffect(() => {
    router.replace('/')
  }, [])
  return null
}
