import Foundation

/// JSON Schema shipped with every request so the user (and ChatGPT) can see the exact contract.
/// Type-specific `answer` requirements are described in the instructions and enforced by `QuestionValidator`.
public enum ResponseSchema {
    public static let json = #"""
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "Braincell question batch",
      "type": "object",
      "required": ["schemaVersion", "requestId", "questions"],
      "additionalProperties": false,
      "properties": {
        "schemaVersion": { "enum": ["cramlab.questions.v2", "cramlab.questions.v1"] },
        "requestId": { "type": "string", "description": "Copy EXACTLY from the request." },
        "questions": { "type": "array", "maxItems": 50, "items": { "$ref": "#/definitions/question" } }
      },
      "definitions": {
        "block": {
          "type": "object",
          "required": ["kind"],
          "properties": {
            "kind": { "enum": ["markdown", "code", "math", "table", "image"] },
            "text": { "type": "string", "description": "markdown and code blocks. Markdown + LaTeX: inline math as \\( ... \\), display math as \\[ ... \\], parts as **Part A.** lines, fenced code for programs." },
            "language": { "type": "string", "description": "code blocks: python, c, java" },
            "latex": { "type": "string", "description": "math blocks (display math, no $ delimiters)" },
            "headers": { "type": "array", "items": { "type": "string" } },
            "rows": { "type": "array", "items": { "type": "array", "items": { "type": "string" } } },
            "ref": { "type": "string" },
            "description": { "type": "string", "description": "image alt text (required for images)" }
          }
        },
        "question": {
          "type": "object",
          "required": ["type", "title", "difficulty", "learningObjective", "content", "answer", "evaluation", "solution"],
          "properties": {
            "importId": { "type": "string", "description": "Unique within this response, e.g. q1" },
            "type": { "enum": ["flashcard", "single_choice", "multiple_select", "short_answer", "numeric", "code_tracing", "coding", "long_form", "derivation_proof"] },
            "title": { "type": "string", "maxLength": 200 },
            "difficulty": { "type": "integer", "minimum": 1, "maximum": 5 },
            "learningObjective": { "type": "string" },
            "content": { "type": "array", "minItems": 1, "items": { "$ref": "#/definitions/block" } },
            "answer": { "type": "object" },
            "evaluation": {
              "type": "object",
              "required": ["method"],
              "properties": {
                "method": { "enum": ["exact", "choice", "numeric", "symbolic", "code_tests", "self_review", "ai_rubric"] },
                "rubric": { "type": "array", "items": { "type": "object", "required": ["criterion", "points"],
                  "properties": { "criterion": { "type": "string" }, "points": { "type": "number", "minimum": 0 } } } }
              }
            },
            "hints": { "type": "array", "maxItems": 10, "items": { "type": "string" } },
            "solution": { "type": "array", "items": { "$ref": "#/definitions/block" } },
            "skills": { "type": "array", "items": { "type": "string" } },
            "assessments": { "type": "array", "items": { "type": "string" } },
            "sources": { "type": "array", "items": { "type": "object", "properties": {
              "document": { "type": "string" }, "page": { "type": "integer" }, "note": { "type": "string" } } } },
            "metadata": { "type": "object", "description": "generator, model, requestId and provenance {slotId, topic, reasoningSkills, primaryArchetype, secondaryArchetypes, origin, sourceRefs, difficultyFactors}" },
            "solutionPlan": { "type": "object", "description": "interpretation, assumptions[], method, formulas[], steps[{description, skill, intermediateResult, commonError}], finalResult, pitfalls[]" }
          }
        }
      }
    }
    """#
}
