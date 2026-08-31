" Vim syntax file for j1pstack .rules files
" Loaded for filetype=nudge_rules

if exists("b:current_syntax")
  finish
endif

syn case match

" Structure
syn match nudgeRulesComment "#.*$" containedin=ALL
syn match nudgeRulesSection "^\s*\[[^]]\+\]" contains=nudgeRulesBracket
syn match nudgeRulesBracket "[][]" contained
syn match nudgeRulesKey "^\s*\zs[a-z_][a-z0-9_-]*\ze\s*="
syn match nudgeRulesEquals "="
syn match nudgeRulesValue "=\s*\zs.*$" contains=nudgeRulesComment,nudgeRulesLevelBlock,nudgeRulesLevelWarn,nudgeRulesLevelInfo,nudgeRulesLevelFix

" Field-specific values
syn match nudgeRulesPath "^\s*\%(in\|context\|except\)\s*=\s*\zs[^#]*" contains=nudgeRulesComment
syn match nudgeRulesPattern "^\s*pattern\s*=\s*\zs.*$" contains=nudgeRulesEscape,nudgeRulesComment
syn match nudgeRulesEscape "\\." contained
syn match nudgeRulesTags "^\s*tags\s*=\s*\zs.*$" contains=nudgeRulesComma,nudgeRulesComment
syn match nudgeRulesComma "," contained

" Semantic level colors
syn keyword nudgeRulesLevelBlock block contained containedin=nudgeRulesValue
syn keyword nudgeRulesLevelWarn warn contained containedin=nudgeRulesValue
syn keyword nudgeRulesLevelInfo info contained containedin=nudgeRulesValue
syn keyword nudgeRulesLevelFix fix contained containedin=nudgeRulesValue

hi def link nudgeRulesComment Comment
hi def link nudgeRulesSection Title
hi def link nudgeRulesBracket Delimiter
hi def link nudgeRulesKey Identifier
hi def link nudgeRulesEquals Operator
hi def link nudgeRulesValue String
hi def link nudgeRulesPath Directory
hi def link nudgeRulesPattern Special
hi def link nudgeRulesEscape SpecialChar
hi def link nudgeRulesTags Type
hi def link nudgeRulesComma Delimiter
hi def link nudgeRulesLevelBlock DiagnosticError
hi def link nudgeRulesLevelWarn DiagnosticWarn
hi def link nudgeRulesLevelInfo DiagnosticInfo
hi def link nudgeRulesLevelFix DiagnosticHint

let b:current_syntax = "nudge_rules"
