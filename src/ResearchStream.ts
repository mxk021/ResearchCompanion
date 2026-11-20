/** Visible text only; DSH remains the authority for the final persisted message. */
export interface AssistantFrame {
  type: 'start' | 'chunk' | 'end'
  attemptId: string
  index?: number
  chunk?: { type: string; index?: number; text?: string; block?: { type: string; text?: string } }
  outcome?: { kind: string; eventType?: string; seq?: number }
}

export class ResearchStream {
  private readonly blocks = new Map<number, string>()
  private nextIndex = 0
  closed = false
  finalSeq?: number

  constructor(readonly id: string) {}

  accept(frame: AssistantFrame): boolean {
    if (frame.attemptId !== this.id || this.closed || frame.index !== this.nextIndex) return false
    if (frame.type === 'end') {
      this.closed = true
      if (frame.outcome?.kind === 'committed' && frame.outcome.eventType === 'assistant/message') {
        this.finalSeq = frame.outcome.seq
      }
      return true
    }
    this.nextIndex++
    const chunk = frame.chunk
    const index = chunk?.index
    if (!chunk || typeof index !== 'number' || !Number.isSafeInteger(index) || index < 0) return false
    if (chunk.type === 'text-delta' && typeof chunk.text === 'string') {
      this.blocks.set(index, (this.blocks.get(index) ?? '') + chunk.text)
      return chunk.text.length > 0
    }
    if (chunk.type === 'block-end' && chunk.block?.type === 'text' && typeof chunk.block.text === 'string') {
      const changed = this.blocks.get(index) !== chunk.block.text
      this.blocks.set(index, chunk.block.text)
      return changed
    }
    return false
  }

  visible(): { id: string; role: 'assistant'; text: string } | null {
    const text = [...this.blocks.keys()].sort((a, b) => a - b).map(index => this.blocks.get(index)).join('\n')
    return text.length > 0 ? { id: 'stream/' + this.id, role: 'assistant', text } : null
  }
}
