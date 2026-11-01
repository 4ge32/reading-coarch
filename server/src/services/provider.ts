import type { PracticeReply, PracticeRequest, TokenReply, TokenRequest, TutorReply, TutorRequest } from '../schemas.js';

export interface TutorProvider {
  token(request: TokenRequest, signal: AbortSignal): Promise<TokenReply>;
  tutor(request: TutorRequest, signal: AbortSignal): Promise<TutorReply>;
  practice(request: PracticeRequest, signal: AbortSignal): Promise<PracticeReply>;
  close?(): Promise<void>;
}
