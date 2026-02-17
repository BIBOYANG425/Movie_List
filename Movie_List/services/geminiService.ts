import { GoogleGenAI, Type } from "@google/genai";
import { RankedItem, Tier } from "../types";

// Note: In a real app, this key should come from process.env.API_KEY.
// For this demo, we assume the user might need to input it or it's pre-configured.
// The component using this service should handle the API Key state.

export class GeminiService {
  private ai: GoogleGenAI;

  constructor(apiKey: string) {
    this.ai = new GoogleGenAI({ apiKey });
  }

  async getRoastAndRecommendations(items: RankedItem[]): Promise<{ roast: string; recommendations: { title: string; reason: string }[] }> {
    const sTier = items.filter(i => i.tier === Tier.S).map(i => i.title).join(', ');
    const dTier = items.filter(i => i.tier === Tier.D).map(i => i.title).join(', ');

    const prompt = `
      Analyze this user's movie and theater taste based on their rankings.
      
      S-Tier (Masterpieces): ${sTier}
      D-Tier (Bad): ${dTier}

      1. Write a short, witty, 2-sentence "roast" of their personality based on these picks.
      2. Recommend 3 items (movies or plays) they haven't listed, explaining why.
    `;

    try {
      const response = await this.ai.models.generateContent({
        model: "gemini-3-flash-preview",
        contents: prompt,
        config: {
          responseMimeType: "application/json",
          responseSchema: {
            type: Type.OBJECT,
            properties: {
              roast: { type: Type.STRING },
              recommendations: {
                type: Type.ARRAY,
                items: {
                  type: Type.OBJECT,
                  properties: {
                    title: { type: Type.STRING },
                    reason: { type: Type.STRING }
                  }
                }
              }
            }
          }
        }
      });

      const text = response.text;
      if (!text) return { roast: "Could not generate insights.", recommendations: [] };
      return JSON.parse(text);

    } catch (error) {
      console.error("Gemini API Error:", error);
      return {
        roast: "Our AI is currently watching a movie. Try again later.",
        recommendations: []
      };
    }
  }
}
