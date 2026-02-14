<#
.SYNOPSIS
NarutoCode テスト用の SVN リポジトリを作成するスクリプト。
C++ プロジェクト風の履歴を持つローカル SVN リポジトリを構築します。

.DESCRIPTION
以下の NarutoCode 分析指標をテストできるよう、意図的にリッチな履歴を作成します：
  - 複数コミッター (alice, bob, charlie)
  - A/M/D/R アクション (追加・修正・削除・リネーム)
  - 同一箇所反復編集 (repeated hunk edits)
  - 自己相殺 / 反転 (self-cancel / revert)
  - 往復 ping-pong (A→B→A)
  - co-change (複数ファイル同時変更)
  - バイナリファイル変更
  - バグ修正キーワード付きメッセージ (fix, bug, hotfix)
  - blame 用の生存行
  - 高 entropy / 低 entropy の変更パターン

.EXAMPLE
.\Create-TestSvnRepo.ps1
.\Create-TestSvnRepo.ps1 -RepoDir C:\temp\svn_repo -WcDir C:\temp\svn_wc
#>
[CmdletBinding()]
param(
    [string]$RepoDir,
    [string]$WcDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- パス設定 ----------
if (-not $RepoDir) { $RepoDir = Join-Path $PSScriptRoot 'repo' }
if (-not $WcDir)   { $WcDir   = Join-Path $PSScriptRoot 'wc' }

$RepoDir = [System.IO.Path]::GetFullPath($RepoDir)
$WcDir   = [System.IO.Path]::GetFullPath($WcDir)

# file:/// URL (Windows 用)
$repoUrl = "file:///$($RepoDir -replace '\\','/')"

Write-Host "=== NarutoCode テスト用 SVN リポジトリ作成 ===" -ForegroundColor Cyan
Write-Host "  リポジトリ : $RepoDir"
Write-Host "  作業コピー : $WcDir"
Write-Host "  URL        : $repoUrl"
Write-Host ""

# ---------- クリーンアップ ----------
if (Test-Path $RepoDir) { Remove-Item $RepoDir -Recurse -Force }
if (Test-Path $WcDir)   { Remove-Item $WcDir   -Recurse -Force }

# ---------- リポジトリ作成 & チェックアウト ----------
Write-Host "[1/3] リポジトリ作成中..." -ForegroundColor Yellow
svnadmin create $RepoDir
if ($LASTEXITCODE -ne 0) { throw "svnadmin create failed" }

# pre-revprop-change フックを設定 (revprop 変更を許可するため)
$hookDir  = Join-Path $RepoDir 'hooks'
$hookFile = Join-Path $hookDir 'pre-revprop-change.bat'
Set-Content -Path $hookFile -Value 'exit 0' -Encoding ASCII

Write-Host "[2/3] チェックアウト中..." -ForegroundColor Yellow
svn checkout $repoUrl $WcDir --quiet
if ($LASTEXITCODE -ne 0) { throw "svn checkout failed" }

# ---------- ヘルパー関数 ----------
function Commit-As {
    param(
        [string]$Author,
        [string]$Message,
        [string]$Date
    )
    Push-Location $WcDir
    try {
        svn commit -m $Message --quiet
        if ($LASTEXITCODE -ne 0) { throw "svn commit failed: $Message" }
        # 最新リビジョン番号を取得
        $info = svn info --xml $repoUrl
        $rev = ([xml]$info).info.entry.revision
        # author を設定
        svn propset svn:author $Author --revprop -r $rev $repoUrl 2>$null
        # date を設定 (任意)
        if ($Date) {
            svn propset svn:date $Date --revprop -r $rev $repoUrl 2>$null
        }
        Write-Host "  r$rev [$Author] $Message" -ForegroundColor DarkGray
    }
    finally {
        Pop-Location
    }
}

function Write-File {
    param([string]$RelPath, [string]$Content)
    $full = Join-Path $WcDir $RelPath
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) {
        New-Item $dir -ItemType Directory -Force | Out-Null
        # 親ディレクトリを svn add (再帰なし)
        $rel = Split-Path $RelPath -Parent
        if ($rel) {
            Push-Location $WcDir
            svn add $rel --depth=empty --parents --quiet 2>$null
            Pop-Location
        }
    }
    Set-Content -Path $full -Value $Content -Encoding UTF8 -NoNewline
}

function Add-File {
    param([string]$RelPath, [string]$Content)
    Write-File -RelPath $RelPath -Content $Content
    Push-Location $WcDir
    svn add $RelPath --quiet 2>$null
    Pop-Location
}

function Write-BinaryFile {
    param([string]$RelPath, [byte[]]$Bytes)
    $full = Join-Path $WcDir $RelPath
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) {
        New-Item $dir -ItemType Directory -Force | Out-Null
        $rel = Split-Path $RelPath -Parent
        if ($rel) {
            Push-Location $WcDir
            svn add $rel --depth=empty --parents --quiet 2>$null
            Pop-Location
        }
    }
    [System.IO.File]::WriteAllBytes($full, $Bytes)
}

function Add-BinaryFile {
    param([string]$RelPath, [byte[]]$Bytes)
    Write-BinaryFile -RelPath $RelPath -Bytes $Bytes
    Push-Location $WcDir
    svn add $RelPath --quiet 2>$null
    # バイナリとしてマーク
    svn propset svn:mime-type application/octet-stream $RelPath --quiet 2>$null
    Pop-Location
}

# ======================================================================
# コミット履歴の作成
# ======================================================================
Write-Host "[3/3] コミット履歴を作成中..." -ForegroundColor Yellow

# -------------------------------------------------------
# r1: alice - プロジェクト初期構造 (A アクション、広い entropy)
# -------------------------------------------------------
Add-File -RelPath 'CMakeLists.txt' -Content @'
cmake_minimum_required(VERSION 3.16)
project(NinjaCalc VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(ninja_calc
    src/main.cpp
    src/calculator.cpp
    src/parser.cpp
    src/utils.cpp
)
target_include_directories(ninja_calc PRIVATE include)
'@

Add-File -RelPath 'include/calculator.h' -Content @'
#ifndef CALCULATOR_H
#define CALCULATOR_H

#include <string>
#include <vector>

namespace ninja {

class Calculator {
public:
    Calculator();
    ~Calculator();

    double evaluate(const std::string& expression);
    void reset();
    double getLastResult() const;

private:
    double lastResult_;
    std::vector<double> history_;
};

} // namespace ninja

#endif // CALCULATOR_H
'@

Add-File -RelPath 'include/parser.h' -Content @'
#ifndef PARSER_H
#define PARSER_H

#include <string>
#include <vector>

namespace ninja {

struct Token {
    enum Type { NUMBER, PLUS, MINUS, MULTIPLY, DIVIDE, LPAREN, RPAREN, END };
    Type type;
    double value;
};

class Parser {
public:
    std::vector<Token> tokenize(const std::string& input);
    double parse(const std::vector<Token>& tokens);

private:
    double parseExpression(const std::vector<Token>& tokens, size_t& pos);
    double parseTerm(const std::vector<Token>& tokens, size_t& pos);
    double parseFactor(const std::vector<Token>& tokens, size_t& pos);
};

} // namespace ninja

#endif // PARSER_H
'@

Add-File -RelPath 'include/utils.h' -Content @'
#ifndef UTILS_H
#define UTILS_H

#include <string>

namespace ninja {
namespace utils {

std::string trim(const std::string& str);
bool isNumeric(const std::string& str);
void printBanner();

} // namespace utils
} // namespace ninja

#endif // UTILS_H
'@

Add-File -RelPath 'src/main.cpp' -Content @'
#include "calculator.h"
#include "utils.h"
#include <iostream>
#include <string>

int main() {
    ninja::utils::printBanner();
    ninja::Calculator calc;

    std::string line;
    while (true) {
        std::cout << "> ";
        if (!std::getline(std::cin, line)) break;

        line = ninja::utils::trim(line);
        if (line == "quit" || line == "exit") break;
        if (line.empty()) continue;

        try {
            double result = calc.evaluate(line);
            std::cout << "= " << result << std::endl;
        } catch (const std::exception& e) {
            std::cerr << "Error: " << e.what() << std::endl;
        }
    }
    return 0;
}
'@

Add-File -RelPath 'src/calculator.cpp' -Content @'
#include "calculator.h"
#include "parser.h"
#include <stdexcept>

namespace ninja {

Calculator::Calculator() : lastResult_(0.0) {}

Calculator::~Calculator() {}

double Calculator::evaluate(const std::string& expression) {
    Parser parser;
    auto tokens = parser.tokenize(expression);
    double result = parser.parse(tokens);
    lastResult_ = result;
    history_.push_back(result);
    return result;
}

void Calculator::reset() {
    lastResult_ = 0.0;
    history_.clear();
}

double Calculator::getLastResult() const {
    return lastResult_;
}

} // namespace ninja
'@

Add-File -RelPath 'src/parser.cpp' -Content @'
#include "parser.h"
#include <stdexcept>
#include <cctype>
#include <sstream>

namespace ninja {

std::vector<Token> Parser::tokenize(const std::string& input) {
    std::vector<Token> tokens;
    size_t i = 0;
    while (i < input.size()) {
        if (std::isspace(input[i])) { ++i; continue; }
        if (std::isdigit(input[i]) || input[i] == '.') {
            std::string num;
            while (i < input.size() && (std::isdigit(input[i]) || input[i] == '.')) {
                num += input[i++];
            }
            tokens.push_back({Token::NUMBER, std::stod(num)});
        } else {
            Token t;
            t.value = 0;
            switch (input[i]) {
                case '+': t.type = Token::PLUS; break;
                case '-': t.type = Token::MINUS; break;
                case '*': t.type = Token::MULTIPLY; break;
                case '/': t.type = Token::DIVIDE; break;
                case '(': t.type = Token::LPAREN; break;
                case ')': t.type = Token::RPAREN; break;
                default: throw std::runtime_error("Unknown character");
            }
            tokens.push_back(t);
            ++i;
        }
    }
    tokens.push_back({Token::END, 0});
    return tokens;
}

double Parser::parse(const std::vector<Token>& tokens) {
    size_t pos = 0;
    return parseExpression(tokens, pos);
}

double Parser::parseExpression(const std::vector<Token>& tokens, size_t& pos) {
    double result = parseTerm(tokens, pos);
    while (pos < tokens.size()) {
        if (tokens[pos].type == Token::PLUS) {
            ++pos;
            result += parseTerm(tokens, pos);
        } else if (tokens[pos].type == Token::MINUS) {
            ++pos;
            result -= parseTerm(tokens, pos);
        } else {
            break;
        }
    }
    return result;
}

double Parser::parseTerm(const std::vector<Token>& tokens, size_t& pos) {
    double result = parseFactor(tokens, pos);
    while (pos < tokens.size()) {
        if (tokens[pos].type == Token::MULTIPLY) {
            ++pos;
            result *= parseFactor(tokens, pos);
        } else if (tokens[pos].type == Token::DIVIDE) {
            ++pos;
            double divisor = parseFactor(tokens, pos);
            if (divisor == 0) throw std::runtime_error("Division by zero");
            result /= divisor;
        } else {
            break;
        }
    }
    return result;
}

double Parser::parseFactor(const std::vector<Token>& tokens, size_t& pos) {
    if (tokens[pos].type == Token::NUMBER) {
        return tokens[pos++].value;
    }
    if (tokens[pos].type == Token::LPAREN) {
        ++pos;
        double result = parseExpression(tokens, pos);
        if (tokens[pos].type != Token::RPAREN) {
            throw std::runtime_error("Missing closing parenthesis");
        }
        ++pos;
        return result;
    }
    if (tokens[pos].type == Token::MINUS) {
        ++pos;
        return -parseFactor(tokens, pos);
    }
    throw std::runtime_error("Unexpected token");
}

} // namespace ninja
'@

Add-File -RelPath 'src/utils.cpp' -Content @'
#include "utils.h"
#include <algorithm>
#include <iostream>

namespace ninja {
namespace utils {

std::string trim(const std::string& str) {
    auto start = str.find_first_not_of(" \t\n\r");
    if (start == std::string::npos) return "";
    auto end = str.find_last_not_of(" \t\n\r");
    return str.substr(start, end - start + 1);
}

bool isNumeric(const std::string& str) {
    if (str.empty()) return false;
    for (char c : str) {
        if (!std::isdigit(c) && c != '.' && c != '-') return false;
    }
    return true;
}

void printBanner() {
    std::cout << "================================" << std::endl;
    std::cout << "  NinjaCalc v1.0" << std::endl;
    std::cout << "  Type 'quit' to exit" << std::endl;
    std::cout << "================================" << std::endl;
}

} // namespace utils
} // namespace ninja
'@

Add-File -RelPath 'README.md' -Content @'
# NinjaCalc

A simple command-line calculator written in C++17.

## Build

```bash
mkdir build && cd build
cmake ..
make
```

## Usage

```bash
./ninja_calc
> 2 + 3
= 5
> (10 - 2) * 3
= 24
```
'@

Commit-As -Author 'alice' -Message 'Initial project structure: CMake build, calculator, parser, utils' -Date '2025-06-01T09:00:00.000000Z'

# -------------------------------------------------------
# r2: bob - テストファイル追加 (A アクション)
# -------------------------------------------------------
Add-File -RelPath 'tests/test_calculator.cpp' -Content @'
#include "calculator.h"
#include <cassert>
#include <iostream>
#include <cmath>

void testBasicAdd() {
    ninja::Calculator calc;
    double r = calc.evaluate("2 + 3");
    assert(std::abs(r - 5.0) < 1e-9);
    std::cout << "PASS: testBasicAdd" << std::endl;
}

void testMultiply() {
    ninja::Calculator calc;
    double r = calc.evaluate("4 * 5");
    assert(std::abs(r - 20.0) < 1e-9);
    std::cout << "PASS: testMultiply" << std::endl;
}

void testParentheses() {
    ninja::Calculator calc;
    double r = calc.evaluate("(2 + 3) * 4");
    assert(std::abs(r - 20.0) < 1e-9);
    std::cout << "PASS: testParentheses" << std::endl;
}

int main() {
    testBasicAdd();
    testMultiply();
    testParentheses();
    std::cout << "All tests passed!" << std::endl;
    return 0;
}
'@

Add-File -RelPath 'tests/test_parser.cpp' -Content @'
#include "parser.h"
#include <cassert>
#include <iostream>

void testTokenize() {
    ninja::Parser parser;
    auto tokens = parser.tokenize("1 + 2");
    assert(tokens.size() == 4);
    assert(tokens[0].type == ninja::Token::NUMBER);
    assert(tokens[1].type == ninja::Token::PLUS);
    assert(tokens[2].type == ninja::Token::NUMBER);
    std::cout << "PASS: testTokenize" << std::endl;
}

void testEmptyInput() {
    ninja::Parser parser;
    auto tokens = parser.tokenize("");
    assert(tokens.size() == 1);
    assert(tokens[0].type == ninja::Token::END);
    std::cout << "PASS: testEmptyInput" << std::endl;
}

int main() {
    testTokenize();
    testEmptyInput();
    std::cout << "All parser tests passed!" << std::endl;
    return 0;
}
'@

Commit-As -Author 'bob' -Message 'Add unit tests for calculator and parser' -Date '2025-06-02T10:30:00.000000Z'

# -------------------------------------------------------
# r3: alice - calculator.cpp を修正 (M アクション、同一箇所反復 #1)
#      evaluate() にログ出力を追加
# -------------------------------------------------------
$calcCpp = Get-Content (Join-Path $WcDir 'src/calculator.cpp') -Raw
$calcCpp = $calcCpp -replace 'double Calculator::evaluate\(const std::string& expression\) \{', @'
double Calculator::evaluate(const std::string& expression) {
    // Log the expression for debugging
    std::cerr << "[DEBUG] Evaluating: " << expression << std::endl;
'@
Write-File -RelPath 'src/calculator.cpp' -Content $calcCpp
Commit-As -Author 'alice' -Message 'Add debug logging to evaluate()' -Date '2025-06-03T11:00:00.000000Z'

# -------------------------------------------------------
# r4: bob - calculator.cpp を修正 (同一箇所反復 → ping-pong 開始: alice→bob)
#      デバッグログを stderr から stdout に変更
# -------------------------------------------------------
$calcCpp = Get-Content (Join-Path $WcDir 'src/calculator.cpp') -Raw
$calcCpp = $calcCpp -replace 'std::cerr << "\[DEBUG\]', 'std::cout << "[TRACE]'
Write-File -RelPath 'src/calculator.cpp' -Content $calcCpp
Commit-As -Author 'bob' -Message 'Change debug output from stderr to stdout' -Date '2025-06-04T14:00:00.000000Z'

# -------------------------------------------------------
# r5: alice - calculator.cpp を修正 (ping-pong: bob→alice, 自己相殺)
#      ログを元に戻す (stderr)
# -------------------------------------------------------
$calcCpp = Get-Content (Join-Path $WcDir 'src/calculator.cpp') -Raw
$calcCpp = $calcCpp -replace 'std::cout << "\[TRACE\]', 'std::cerr << "[DEBUG]'
Write-File -RelPath 'src/calculator.cpp' -Content $calcCpp
Commit-As -Author 'alice' -Message 'Revert: use stderr for debug output, not stdout' -Date '2025-06-05T09:30:00.000000Z'

# -------------------------------------------------------
# r6: charlie - 新機能 modulo 演算子追加 (A + M、co-change 多ファイル)
# -------------------------------------------------------
# parser.h に MODULO トークン追加
$parserH = Get-Content (Join-Path $WcDir 'include/parser.h') -Raw
$parserH = $parserH -replace 'DIVIDE, LPAREN', 'DIVIDE, MODULO, LPAREN'
Write-File -RelPath 'include/parser.h' -Content $parserH

# parser.cpp に % 対応追加
$parserCpp = Get-Content (Join-Path $WcDir 'src/parser.cpp') -Raw
$parserCpp = $parserCpp -replace "case '/': t.type = Token::DIVIDE; break;", @"
case '/': t.type = Token::DIVIDE; break;
                case '%': t.type = Token::MODULO; break;
"@
# parseTerm に modulo 処理を追加
$parserCpp = $parserCpp -replace '(\s+result /= divisor;\s+\} else \{)', @'
            result /= divisor;
        } else if (tokens[pos].type == Token::MODULO) {
            ++pos;
            double divisor = parseFactor(tokens, pos);
            if (divisor == 0) throw std::runtime_error("Modulo by zero");
            result = static_cast<double>(static_cast<long long>(result) % static_cast<long long>(divisor));
        } else {
'@
Write-File -RelPath 'src/parser.cpp' -Content $parserCpp

# テスト追加
$testCalc = Get-Content (Join-Path $WcDir 'tests/test_calculator.cpp') -Raw
$testCalc = $testCalc -replace 'int main\(\) \{', @'
void testModulo() {
    ninja::Calculator calc;
    double r = calc.evaluate("10 % 3");
    assert(std::abs(r - 1.0) < 1e-9);
    std::cout << "PASS: testModulo" << std::endl;
}

int main() {
'@
$testCalc = $testCalc -replace 'testParentheses\(\);', "testParentheses();`n    testModulo();"
Write-File -RelPath 'tests/test_calculator.cpp' -Content $testCalc

Commit-As -Author 'charlie' -Message '#101 Add modulo (%) operator support' -Date '2025-06-07T16:00:00.000000Z'

# -------------------------------------------------------
# r7: bob - バイナリファイル追加 (バイナリ変更検出テスト)
# -------------------------------------------------------
$logoBytes = [byte[]]@(
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  # PNG header
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  # IHDR chunk
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # 1x1 px
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
    0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82
)
Add-BinaryFile -RelPath 'assets/logo.png' -Bytes $logoBytes
Commit-As -Author 'bob' -Message 'Add project logo (binary asset)' -Date '2025-06-08T10:00:00.000000Z'

# -------------------------------------------------------
# r8: alice - utils.cpp の大きなリファクタ (高 churn)
# -------------------------------------------------------
Write-File -RelPath 'src/utils.cpp' -Content @'
#include "utils.h"
#include <algorithm>
#include <iostream>
#include <cctype>
#include <sstream>

namespace ninja {
namespace utils {

std::string trim(const std::string& str) {
    if (str.empty()) return str;
    auto start = std::find_if(str.begin(), str.end(),
        [](unsigned char c) { return !std::isspace(c); });
    auto end = std::find_if(str.rbegin(), str.rend(),
        [](unsigned char c) { return !std::isspace(c); }).base();
    return (start < end) ? std::string(start, end) : std::string();
}

bool isNumeric(const std::string& str) {
    if (str.empty()) return false;
    std::istringstream iss(str);
    double d;
    iss >> std::noskipws >> d;
    return iss.eof() && !iss.fail();
}

std::string toLower(const std::string& str) {
    std::string result = str;
    std::transform(result.begin(), result.end(), result.begin(),
        [](unsigned char c) { return std::tolower(c); });
    return result;
}

void printBanner() {
    std::cout << "+================================+" << std::endl;
    std::cout << "|       NinjaCalc v1.1           |" << std::endl;
    std::cout << "|   Type 'quit' to exit          |" << std::endl;
    std::cout << "|   Type 'help' for commands     |" << std::endl;
    std::cout << "+================================+" << std::endl;
}

void printHelp() {
    std::cout << "Commands:" << std::endl;
    std::cout << "  <expression>  Evaluate math expression" << std::endl;
    std::cout << "  help          Show this help" << std::endl;
    std::cout << "  history       Show calculation history" << std::endl;
    std::cout << "  quit/exit     Exit the program" << std::endl;
}

} // namespace utils
} // namespace ninja
'@

# utils.h にも追加
Write-File -RelPath 'include/utils.h' -Content @'
#ifndef UTILS_H
#define UTILS_H

#include <string>

namespace ninja {
namespace utils {

std::string trim(const std::string& str);
bool isNumeric(const std::string& str);
std::string toLower(const std::string& str);
void printBanner();
void printHelp();

} // namespace utils
} // namespace ninja

#endif // UTILS_H
'@

Commit-As -Author 'alice' -Message 'Refactor utils: improve trim/isNumeric, add toLower and help' -Date '2025-06-10T13:00:00.000000Z'

# -------------------------------------------------------
# r9: charlie - parser.cpp のバグ修正 (fix keyword)
# -------------------------------------------------------
$parserCpp = Get-Content (Join-Path $WcDir 'src/parser.cpp') -Raw
$parserCpp = $parserCpp -replace 'if \(std::isdigit\(input\[i\]\) \|\| input\[i\] == ''\.''\)', 'if (std::isdigit(input[i]) || (input[i] == ''.'' && i + 1 < input.size() && std::isdigit(input[i+1])))'
Write-File -RelPath 'src/parser.cpp' -Content $parserCpp
Commit-As -Author 'charlie' -Message 'fix: handle leading decimal point in tokenizer (bug #42)' -Date '2025-06-11T15:30:00.000000Z'

# -------------------------------------------------------
# r10: bob - 新ファイル追加 → 後で削除される運命 (D アクション準備)
# -------------------------------------------------------
Add-File -RelPath 'src/logger.cpp' -Content @'
#include <iostream>
#include <fstream>
#include <ctime>

namespace ninja {

class Logger {
public:
    static Logger& instance() {
        static Logger logger;
        return logger;
    }

    void log(const std::string& msg) {
        auto now = std::time(nullptr);
        std::cerr << "[" << now << "] " << msg << std::endl;
    }

    void setFile(const std::string& path) {
        logFile_.open(path, std::ios::app);
    }

private:
    Logger() = default;
    std::ofstream logFile_;
};

} // namespace ninja
'@

Add-File -RelPath 'include/logger.h' -Content @'
#ifndef LOGGER_H
#define LOGGER_H

#include <string>

namespace ninja {

class Logger {
public:
    static Logger& instance();
    void log(const std::string& msg);
    void setFile(const std::string& path);

private:
    Logger() = default;
};

} // namespace ninja

#endif // LOGGER_H
'@

Commit-As -Author 'bob' -Message 'Add Logger class for future diagnostics' -Date '2025-06-12T11:00:00.000000Z'

# -------------------------------------------------------
# r11: alice - calculator.cpp にヒストリ表示機能追加 (M、同一箇所反復 #2)
# -------------------------------------------------------
$calcH = Get-Content (Join-Path $WcDir 'include/calculator.h') -Raw
$calcH = $calcH -replace 'double getLastResult\(\) const;', @'
double getLastResult() const;
    const std::vector<double>& getHistory() const;
    void printHistory() const;
'@
Write-File -RelPath 'include/calculator.h' -Content $calcH

$calcCpp = Get-Content (Join-Path $WcDir 'src/calculator.cpp') -Raw
$calcCpp = $calcCpp -replace '} // namespace ninja', @'
const std::vector<double>& Calculator::getHistory() const {
    return history_;
}

void Calculator::printHistory() const {
    std::cout << "History:" << std::endl;
    for (size_t i = 0; i < history_.size(); ++i) {
        std::cout << "  [" << i << "] " << history_[i] << std::endl;
    }
}

} // namespace ninja
'@
Write-File -RelPath 'src/calculator.cpp' -Content $calcCpp

Commit-As -Author 'alice' -Message 'Add calculation history display feature' -Date '2025-06-14T09:00:00.000000Z'

# -------------------------------------------------------
# r12: charlie - logger 削除 (D アクション)
# -------------------------------------------------------
Push-Location $WcDir
svn delete 'src/logger.cpp' --quiet
svn delete 'include/logger.h' --quiet
Pop-Location
Commit-As -Author 'charlie' -Message 'Remove Logger class (replaced by simple stderr output)' -Date '2025-06-15T10:00:00.000000Z'

# -------------------------------------------------------
# r13: bob - ファイルリネーム (R アクション)
#       utils.cpp → string_utils.cpp
# -------------------------------------------------------
Push-Location $WcDir
svn rename 'src/utils.cpp' 'src/string_utils.cpp' --quiet
svn rename 'include/utils.h' 'include/string_utils.h' --quiet
Pop-Location

# ヘッダーのインクルードガードを更新
$suh = Get-Content (Join-Path $WcDir 'include/string_utils.h') -Raw
$suh = $suh -replace 'UTILS_H', 'STRING_UTILS_H'
Write-File -RelPath 'include/string_utils.h' -Content $suh

# include を更新
$sucpp = Get-Content (Join-Path $WcDir 'src/string_utils.cpp') -Raw
$sucpp = $sucpp -replace '#include "utils.h"', '#include "string_utils.h"'
Write-File -RelPath 'src/string_utils.cpp' -Content $sucpp

$mainCpp = Get-Content (Join-Path $WcDir 'src/main.cpp') -Raw
$mainCpp = $mainCpp -replace '#include "utils.h"', '#include "string_utils.h"'
Write-File -RelPath 'src/main.cpp' -Content $mainCpp

Commit-As -Author 'bob' -Message 'Rename utils to string_utils for clarity' -Date '2025-06-16T14:00:00.000000Z'

# -------------------------------------------------------
# r14: alice - calculator.cpp のデバッグログを削除 (自己相殺の完了)
# -------------------------------------------------------
$calcCpp = Get-Content (Join-Path $WcDir 'src/calculator.cpp') -Raw
$calcCpp = $calcCpp -replace '(?m)\s+// Log the expression for debugging\r?\n\s+std::cerr << "\[DEBUG\] Evaluating: " << expression << std::endl;\r?\n', "`n"
Write-File -RelPath 'src/calculator.cpp' -Content $calcCpp
Commit-As -Author 'alice' -Message 'Remove debug logging from evaluate() - no longer needed' -Date '2025-06-17T11:00:00.000000Z'

# -------------------------------------------------------
# r15: bob - バイナリファイル更新 (バイナリ変更)
# -------------------------------------------------------
$newLogo = [byte[]]@(
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,  # 2x2 px に変更
    0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A,
    0x73, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0x4F, 0x00, 0x01,
    0x00, 0x01, 0x00, 0x00, 0x18, 0xDD, 0x8D, 0xB4,
    0x48, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82
)
Write-BinaryFile -RelPath 'assets/logo.png' -Bytes $newLogo
Commit-As -Author 'bob' -Message 'Update logo to 2x2 version' -Date '2025-06-18T10:00:00.000000Z'

# -------------------------------------------------------
# r16: charlie - 大量の小さな修正 (低 entropy: 1 ファイルに集中)
# -------------------------------------------------------
$parserCpp = Get-Content (Join-Path $WcDir 'src/parser.cpp') -Raw
$parserCpp = $parserCpp -replace "throw std::runtime_error\(`"Division by zero`"\);", 'throw std::runtime_error("Division by zero: divisor must not be zero");'
$parserCpp = $parserCpp -replace "throw std::runtime_error\(`"Modulo by zero`"\);", 'throw std::runtime_error("Modulo by zero: divisor must not be zero");'
$parserCpp = $parserCpp -replace "throw std::runtime_error\(`"Unknown character`"\);", 'throw std::runtime_error("Unknown character in expression");'
$parserCpp = $parserCpp -replace "throw std::runtime_error\(`"Missing closing parenthesis`"\);", 'throw std::runtime_error("Syntax error: missing closing parenthesis");'
$parserCpp = $parserCpp -replace "throw std::runtime_error\(`"Unexpected token`"\);", 'throw std::runtime_error("Syntax error: unexpected token");'
Write-File -RelPath 'src/parser.cpp' -Content $parserCpp
Commit-As -Author 'charlie' -Message 'Improve error messages in parser for better diagnostics' -Date '2025-06-19T16:30:00.000000Z'

# -------------------------------------------------------
# r17: alice & bob - co-change: .gitignore と CMakeLists.txt を同時修正
# -------------------------------------------------------
Add-File -RelPath '.gitignore' -Content @'
build/
*.o
*.exe
CMakeCache.txt
CMakeFiles/
cmake_install.cmake
Makefile
'@

$cmake = Get-Content (Join-Path $WcDir 'CMakeLists.txt') -Raw
$cmake = $cmake -replace 'project\(NinjaCalc VERSION 1.0.0', 'project(NinjaCalc VERSION 1.1.0'
$cmake += @'

# Tests
enable_testing()
add_executable(test_calculator tests/test_calculator.cpp src/calculator.cpp src/parser.cpp)
target_include_directories(test_calculator PRIVATE include)
add_test(NAME calculator_tests COMMAND test_calculator)

add_executable(test_parser tests/test_parser.cpp src/parser.cpp)
target_include_directories(test_parser PRIVATE include)
add_test(NAME parser_tests COMMAND test_parser)
'@
Write-File -RelPath 'CMakeLists.txt' -Content $cmake

Commit-As -Author 'alice' -Message 'Bump version to 1.1.0, add CTest support and .gitignore' -Date '2025-06-20T09:00:00.000000Z'

# -------------------------------------------------------
# r18: bob - hotfix: calculator の reset にバグ (fix keyword)
# -------------------------------------------------------
$calcCpp = Get-Content (Join-Path $WcDir 'src/calculator.cpp') -Raw
$calcCpp = $calcCpp -replace 'void Calculator::reset\(\) \{\s*\r?\n\s+lastResult_ = 0\.0;\s*\r?\n\s+history_\.clear\(\);', @'
void Calculator::reset() {
    lastResult_ = 0.0;
    history_.clear();
    // Notify reset event
    std::cerr << "[INFO] Calculator reset" << std::endl;
'@
Write-File -RelPath 'src/calculator.cpp' -Content $calcCpp
Commit-As -Author 'bob' -Message 'hotfix: add reset notification for debugging #55' -Date '2025-06-21T18:00:00.000000Z'

# -------------------------------------------------------
# r19: charlie - 大きな新ファイル (高 churn + 新規)
# -------------------------------------------------------
Add-File -RelPath 'src/formatter.cpp' -Content @'
#include <string>
#include <sstream>
#include <iomanip>
#include <cmath>
#include <vector>
#include <algorithm>

namespace ninja {

class Formatter {
public:
    enum class Style { FIXED, SCIENTIFIC, AUTO };

    static std::string format(double value, Style style = Style::AUTO, int precision = 6) {
        std::ostringstream oss;
        switch (style) {
            case Style::FIXED:
                oss << std::fixed << std::setprecision(precision) << value;
                break;
            case Style::SCIENTIFIC:
                oss << std::scientific << std::setprecision(precision) << value;
                break;
            case Style::AUTO:
                if (std::abs(value) > 1e6 || (std::abs(value) < 1e-4 && value != 0)) {
                    oss << std::scientific << std::setprecision(precision) << value;
                } else {
                    oss << std::fixed << std::setprecision(precision) << value;
                    // Remove trailing zeros
                    std::string s = oss.str();
                    size_t dot = s.find('.');
                    if (dot != std::string::npos) {
                        size_t last = s.find_last_not_of('0');
                        if (last == dot) last++;
                        return s.substr(0, last + 1);
                    }
                    return s;
                }
                break;
        }
        return oss.str();
    }

    static std::string formatWithCommas(double value) {
        std::string num = std::to_string(static_cast<long long>(value));
        int insertPos = static_cast<int>(num.length()) - 3;
        while (insertPos > 0) {
            num.insert(insertPos, ",");
            insertPos -= 3;
        }
        return num;
    }

    static std::string formatPercent(double value, int precision = 2) {
        std::ostringstream oss;
        oss << std::fixed << std::setprecision(precision) << (value * 100.0) << "%";
        return oss.str();
    }

    static std::string formatBytes(long long bytes) {
        const char* units[] = {"B", "KB", "MB", "GB", "TB"};
        int unitIdx = 0;
        double size = static_cast<double>(bytes);
        while (size >= 1024.0 && unitIdx < 4) {
            size /= 1024.0;
            unitIdx++;
        }
        std::ostringstream oss;
        oss << std::fixed << std::setprecision(2) << size << " " << units[unitIdx];
        return oss.str();
    }
};

} // namespace ninja
'@

Add-File -RelPath 'include/formatter.h' -Content @'
#ifndef FORMATTER_H
#define FORMATTER_H

#include <string>

namespace ninja {

class Formatter {
public:
    enum class Style { FIXED, SCIENTIFIC, AUTO };

    static std::string format(double value, Style style = Style::AUTO, int precision = 6);
    static std::string formatWithCommas(double value);
    static std::string formatPercent(double value, int precision = 2);
    static std::string formatBytes(long long bytes);
};

} // namespace ninja

#endif // FORMATTER_H
'@

Commit-As -Author 'charlie' -Message 'Add Formatter class with multiple output styles' -Date '2025-06-22T14:00:00.000000Z'

# -------------------------------------------------------
# r20: alice - README を更新 + main.cpp に help コマンド対応
# -------------------------------------------------------
Write-File -RelPath 'README.md' -Content @'
# NinjaCalc v1.1

A simple command-line calculator written in C++17.

## Features
- Basic arithmetic: +, -, *, /, %
- Parentheses grouping
- Calculation history
- Multiple output formats

## Build

```bash
mkdir build && cd build
cmake ..
make
```

## Usage

```bash
./ninja_calc
> 2 + 3
= 5
> (10 - 2) * 3
= 24
> 10 % 3
= 1
> help
> history
> quit
```

## License
MIT
'@

$mainCpp = Get-Content (Join-Path $WcDir 'src/main.cpp') -Raw
$mainCpp = $mainCpp -replace 'if \(line\.empty\(\)\) continue;', @'
if (line.empty()) continue;

        if (line == "help") {
            ninja::utils::printHelp();
            continue;
        }
        if (line == "history") {
            calc.printHistory();
            continue;
        }
'@
Write-File -RelPath 'src/main.cpp' -Content $mainCpp

Commit-As -Author 'alice' -Message 'Update README for v1.1, add help and history commands to REPL' -Date '2025-06-23T10:30:00.000000Z'

# ======================================================================
# 完了
# ======================================================================
Write-Host ""
Write-Host "=== テスト用 SVN リポジトリ作成完了！ ===" -ForegroundColor Green
Write-Host ""
Write-Host "リポジトリ URL: $repoUrl" -ForegroundColor Cyan
Write-Host "リビジョン範囲: r1 〜 r20" -ForegroundColor Cyan
Write-Host ""
Write-Host "NarutoCode で分析するには:" -ForegroundColor Yellow
Write-Host "  .\NarutoCode.ps1 -RepoUrl '$repoUrl' -FromRev 1 -ToRev 20 -OutDir .\tests\fixtures\expected_output -EmitPlantUml" -ForegroundColor White
Write-Host ""
Write-Host "コミッター:" -ForegroundColor Yellow
Write-Host "  alice   - 8 commits (r1,r3,r5,r8,r11,r14,r17,r20)" -ForegroundColor White
Write-Host "  bob     - 7 commits (r2,r4,r7,r10,r13,r15,r18)" -ForegroundColor White
Write-Host "  charlie - 5 commits (r6,r9,r12,r16,r19)" -ForegroundColor White
Write-Host ""
Write-Host "テスト対象の指標:" -ForegroundColor Yellow
Write-Host "  - A/M/D/R アクション    (r1,r3,r12,r13)" -ForegroundColor White
Write-Host "  - 同一箇所反復          (alice: calculator.cpp r3,r5,r14)" -ForegroundColor White
Write-Host "  - 自己相殺              (alice: debug log add r3 -> remove r14)" -ForegroundColor White
Write-Host "  - ping-pong             (alice->bob->alice: r3,r4,r5)" -ForegroundColor White
Write-Host "  - co-change             (r6: 4ファイル同時, r17: 2ファイル同時)" -ForegroundColor White
Write-Host "  - バイナリ変更          (r7,r15: logo.png)" -ForegroundColor White
Write-Host "  - fix/hotfix キーワード (r9,r18)" -ForegroundColor White
Write-Host "  - 高/低 churn           (r8: 高churn, r16: 集中編集)" -ForegroundColor White
Write-Host "  - リネーム              (r13: utils→string_utils)" -ForegroundColor White




