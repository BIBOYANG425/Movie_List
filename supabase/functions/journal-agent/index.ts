import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
}

const MOOD_TAG_IDS = [
  'inspired',
  'joyful',
  'thrilled',
  'moved',
  'amazed',
  'comforted',
  'hopeful',
  'thoughtful',
  'nostalgic',
  'melancholy',
  'haunted',
  'contemplative',
  'tense',
  'disturbed',
  'heartbroken',
  'angry',
  'overwhelmed',
  'exhausted',
  'amused',
  'charmed',
  'entertained',
  'relaxed',
  'satisfied',
] as const

interface MovieContext {
  title: string
  year: string
  genres: string[]
  director?: string
}

interface RankingContext {
  tier: string
  score: number
  primaryGenre?: string
}

interface UserProfileContext {
  moodHistory: string[]
  topGenres: Record<string, number>
  recentJournalCount: number
}

interface RequestBody {
  messages: { role: 'user' | 'assistant' | 'system'; content: string }[]
  context: {
    movie: MovieContext
    ranking: RankingContext
    userProfile: UserProfileContext
  }
  action: 'chat' | 'generate_review'
}

interface KimiResponse {
  choices: { message: { content: string } }[]
  usage: {
    prompt_tokens: number
    completion_tokens: number
    total_tokens: number
  }
}

function buildChatSystemPrompt(
  movie: MovieContext,
  ranking: RankingContext,
  userProfile: UserProfileContext
): string {
  const topGenres = Object.entries(userProfile.topGenres)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 3)
    .map(([genre]) => genre)
    .join(', ')

  const moodHistory =
    userProfile.moodHistory.length > 0
      ? userProfile.moodHistory.slice(-5).join(', ')
      : 'none yet'

  return `You are a warm, perceptive movie journal assistant for Spool. Your job is to help the user reflect on their experience watching ${movie.title} (${movie.year}).

The user rated this ${ranking.tier}-tier. Their taste leans toward ${topGenres || 'a wide variety of genres'}. Recent moods: ${moodHistory}.

Ask 2-3 thoughtful, specific questions about:
- Their emotional response (what stayed with them)
- A specific moment or scene that stood out
- How this compares to their expectations or similar films

Be conversational, not clinical. Match your tone to the tier — S-tier = genuine enthusiasm, D-tier = empathetic curiosity about what didn't work. Keep messages concise (2-3 sentences max per question).`
}

function buildGenerateReviewSystemPrompt(): string {
  return `Based on the conversation, generate a structured movie journal entry. Output valid JSON only, no markdown fences or extra text:
{
  "review_text": "A 2-4 paragraph review in the user's own voice...",
  "mood_tags": ["tag1", "tag2"],
  "favorite_moments": ["moment1", "moment2"],
  "personal_takeaway": "One sentence personal reflection...",
  "standout_performances": ["Actor Name as Character"]
}

Use the user's actual words and perspectives. Match their tone and vocabulary. mood_tags must come from the allowed list: ${JSON.stringify(MOOD_TAG_IDS)}`
}

function validateRequestBody(
  body: unknown
): { valid: true; data: RequestBody } | { valid: false; error: string } {
  if (!body || typeof body !== 'object') {
    return { valid: false, error: 'Request body must be a JSON object' }
  }

  const b = body as Record<string, unknown>

  if (!Array.isArray(b.messages) || b.messages.length === 0) {
    return { valid: false, error: 'messages must be a non-empty array' }
  }

  for (const msg of b.messages) {
    if (
      !msg ||
      typeof msg !== 'object' ||
      !('role' in msg) ||
      !('content' in msg)
    ) {
      return {
        valid: false,
        error: 'Each message must have role and content fields',
      }
    }
    if (!['user', 'assistant', 'system'].includes((msg as { role: string }).role)) {
      return {
        valid: false,
        error: 'Message role must be user, assistant, or system',
      }
    }
  }

  if (!b.context || typeof b.context !== 'object') {
    return { valid: false, error: 'context is required' }
  }

  const ctx = b.context as Record<string, unknown>

  if (!ctx.movie || typeof ctx.movie !== 'object') {
    return { valid: false, error: 'context.movie is required' }
  }

  const movie = ctx.movie as Record<string, unknown>
  if (!movie.title || typeof movie.title !== 'string') {
    return { valid: false, error: 'context.movie.title is required' }
  }
  if (!movie.year || typeof movie.year !== 'string') {
    return { valid: false, error: 'context.movie.year is required' }
  }
  if (!Array.isArray(movie.genres)) {
    return { valid: false, error: 'context.movie.genres must be an array' }
  }

  if (!ctx.ranking || typeof ctx.ranking !== 'object') {
    return { valid: false, error: 'context.ranking is required' }
  }

  const ranking = ctx.ranking as Record<string, unknown>
  if (!ranking.tier || typeof ranking.tier !== 'string') {
    return { valid: false, error: 'context.ranking.tier is required' }
  }
  if (typeof ranking.score !== 'number') {
    return { valid: false, error: 'context.ranking.score must be a number' }
  }

  if (!ctx.userProfile || typeof ctx.userProfile !== 'object') {
    return { valid: false, error: 'context.userProfile is required' }
  }

  const profile = ctx.userProfile as Record<string, unknown>
  if (!Array.isArray(profile.moodHistory)) {
    return {
      valid: false,
      error: 'context.userProfile.moodHistory must be an array',
    }
  }
  if (!profile.topGenres || typeof profile.topGenres !== 'object') {
    return {
      valid: false,
      error: 'context.userProfile.topGenres must be an object',
    }
  }
  if (typeof profile.recentJournalCount !== 'number') {
    return {
      valid: false,
      error: 'context.userProfile.recentJournalCount must be a number',
    }
  }

  if (!b.action || !['chat', 'generate_review'].includes(b.action as string)) {
    return {
      valid: false,
      error: 'action must be "chat" or "generate_review"',
    }
  }

  return { valid: true, data: b as unknown as RequestBody }
}

async function callKimiAPI(
  systemPrompt: string,
  messages: RequestBody['messages']
): Promise<KimiResponse> {
  const apiKey = Deno.env.get('MOONSHOT_API_KEY')
  if (!apiKey) {
    throw new Error('MOONSHOT_API_KEY is not configured')
  }

  const response = await fetch('https://api.moonshot.cn/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: 'kimi-latest',
      messages: [
        { role: 'system', content: systemPrompt },
        ...messages,
      ],
      temperature: 0.7,
    }),
  })

  if (!response.ok) {
    const errorText = await response.text().catch(() => 'Unknown error')
    throw new Error(
      `Kimi API returned ${response.status}: ${errorText}`
    )
  }

  const data = await response.json()
  return data as KimiResponse
}

function parseGenerationOutput(raw: string): Record<string, unknown> | null {
  // Try direct JSON parse first
  try {
    return JSON.parse(raw)
  } catch {
    // Fall through
  }

  // Try extracting JSON from markdown code fences
  const fenceMatch = raw.match(/```(?:json)?\s*([\s\S]*?)```/)
  if (fenceMatch) {
    try {
      return JSON.parse(fenceMatch[1].trim())
    } catch {
      // Fall through
    }
  }

  // Try finding first { ... } block
  const braceMatch = raw.match(/\{[\s\S]*\}/)
  if (braceMatch) {
    try {
      return JSON.parse(braceMatch[0])
    } catch {
      // Fall through
    }
  }

  return null
}

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ error: 'Method not allowed' }),
      {
        status: 405,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  }

  try {
    // --- Auth: verify Supabase JWT ---
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing Authorization header' }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    })

    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser()

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token' }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // --- Parse and validate request body ---
    let rawBody: unknown
    try {
      rawBody = await req.json()
    } catch {
      return new Response(
        JSON.stringify({ error: 'Invalid JSON in request body' }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    const validation = validateRequestBody(rawBody)
    if (!validation.valid) {
      return new Response(
        JSON.stringify({ error: validation.error }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    const { messages, context, action } = validation.data

    // --- Build system prompt and call Kimi ---
    if (action === 'chat') {
      const systemPrompt = buildChatSystemPrompt(
        context.movie,
        context.ranking,
        context.userProfile
      )

      let kimiResponse: KimiResponse
      try {
        kimiResponse = await callKimiAPI(systemPrompt, messages)
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Kimi API call failed'
        return new Response(
          JSON.stringify({ error: `AI service error: ${message}` }),
          {
            status: 502,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          }
        )
      }

      const reply = kimiResponse.choices?.[0]?.message?.content
      if (!reply) {
        return new Response(
          JSON.stringify({ error: 'No response from AI service' }),
          {
            status: 502,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          }
        )
      }

      return new Response(
        JSON.stringify({
          reply,
          usage: {
            prompt_tokens: kimiResponse.usage.prompt_tokens,
            completion_tokens: kimiResponse.usage.completion_tokens,
          },
        }),
        {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // --- action: generate_review ---
    const systemPrompt = buildGenerateReviewSystemPrompt()

    let kimiResponse: KimiResponse
    try {
      kimiResponse = await callKimiAPI(systemPrompt, messages)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Kimi API call failed'
      return new Response(
        JSON.stringify({ error: `AI service error: ${message}` }),
        {
          status: 502,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    const rawOutput = kimiResponse.choices?.[0]?.message?.content
    if (!rawOutput) {
      return new Response(
        JSON.stringify({ error: 'No response from AI service' }),
        {
          status: 502,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    const parsed = parseGenerationOutput(rawOutput)
    if (!parsed) {
      return new Response(
        JSON.stringify({
          error: 'Failed to parse structured output from AI',
          raw_output: rawOutput,
        }),
        {
          status: 502,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // Validate and filter mood_tags to only allowed values
    if (Array.isArray(parsed.mood_tags)) {
      parsed.mood_tags = (parsed.mood_tags as string[]).filter((tag) =>
        (MOOD_TAG_IDS as readonly string[]).includes(tag)
      )
    }

    return new Response(
      JSON.stringify({
        generation: {
          review_text: parsed.review_text ?? '',
          mood_tags: parsed.mood_tags ?? [],
          favorite_moments: parsed.favorite_moments ?? [],
          personal_takeaway: parsed.personal_takeaway ?? '',
          standout_performances: parsed.standout_performances ?? [],
        },
        raw_output: rawOutput,
        usage: {
          prompt_tokens: kimiResponse.usage.prompt_tokens,
          completion_tokens: kimiResponse.usage.completion_tokens,
        },
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Internal server error'
    console.error('journal-agent error:', err)
    return new Response(
      JSON.stringify({ error: message }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  }
})
