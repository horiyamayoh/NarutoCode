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
# ベンチマーク用 大量コミット生成 (r21 〜 r220)
# ======================================================================
Write-Host ""
Write-Host "[BENCH] ベンチマーク用大量コミット生成を開始..." -ForegroundColor Magenta

# ---------- コミッター定義 ----------
$authors = @('alice', 'bob', 'charlie', 'dave', 'eve')

# ---------- Phase 1: 新ファイル群の追加 (r21 〜 r40) ----------
# 多数のソースファイルを追加し、ファイルツリーを拡大する
Write-Host "  [Phase 1] 新ファイル群の一括追加 (r21 〜 r40)..." -ForegroundColor Yellow

# --- r21: dave - math_functions モジュール追加 ---
Add-File -RelPath 'src/math_functions.cpp' -Content @'
#include "math_functions.h"
#include <cmath>
#include <stdexcept>
#include <numeric>
#include <algorithm>
#include <vector>

namespace ninja {
namespace math {

double factorial(int n) {
    if (n < 0) throw std::invalid_argument("Negative factorial");
    if (n <= 1) return 1.0;
    double result = 1.0;
    for (int i = 2; i <= n; ++i) {
        result *= i;
    }
    return result;
}

double power(double base, int exponent) {
    if (exponent == 0) return 1.0;
    if (exponent < 0) return 1.0 / power(base, -exponent);
    double result = 1.0;
    for (int i = 0; i < exponent; ++i) {
        result *= base;
    }
    return result;
}

double fibonacci(int n) {
    if (n < 0) throw std::invalid_argument("Negative fibonacci index");
    if (n <= 1) return static_cast<double>(n);
    double a = 0, b = 1;
    for (int i = 2; i <= n; ++i) {
        double temp = a + b;
        a = b;
        b = temp;
    }
    return b;
}

double gcd(double a, double b) {
    long long x = static_cast<long long>(std::abs(a));
    long long y = static_cast<long long>(std::abs(b));
    while (y != 0) {
        long long temp = y;
        y = x % y;
        x = temp;
    }
    return static_cast<double>(x);
}

double lcm(double a, double b) {
    if (a == 0 || b == 0) return 0;
    return std::abs(a * b) / gcd(a, b);
}

double mean(const std::vector<double>& values) {
    if (values.empty()) throw std::invalid_argument("Empty dataset");
    double sum = std::accumulate(values.begin(), values.end(), 0.0);
    return sum / static_cast<double>(values.size());
}

double median(std::vector<double> values) {
    if (values.empty()) throw std::invalid_argument("Empty dataset");
    std::sort(values.begin(), values.end());
    size_t n = values.size();
    if (n % 2 == 0) {
        return (values[n/2 - 1] + values[n/2]) / 2.0;
    }
    return values[n/2];
}

double standardDeviation(const std::vector<double>& values) {
    if (values.size() < 2) throw std::invalid_argument("Need at least 2 values");
    double m = mean(values);
    double sumSq = 0.0;
    for (double v : values) {
        double diff = v - m;
        sumSq += diff * diff;
    }
    return std::sqrt(sumSq / static_cast<double>(values.size() - 1));
}

double clamp(double value, double minVal, double maxVal) {
    if (minVal > maxVal) throw std::invalid_argument("min > max");
    return std::max(minVal, std::min(value, maxVal));
}

double lerp(double a, double b, double t) {
    return a + t * (b - a);
}

double degToRad(double degrees) {
    return degrees * 3.14159265358979323846 / 180.0;
}

double radToDeg(double radians) {
    return radians * 180.0 / 3.14159265358979323846;
}

} // namespace math
} // namespace ninja
'@

Add-File -RelPath 'include/math_functions.h' -Content @'
#ifndef MATH_FUNCTIONS_H
#define MATH_FUNCTIONS_H

#include <vector>

namespace ninja {
namespace math {

double factorial(int n);
double power(double base, int exponent);
double fibonacci(int n);
double gcd(double a, double b);
double lcm(double a, double b);
double mean(const std::vector<double>& values);
double median(std::vector<double> values);
double standardDeviation(const std::vector<double>& values);
double clamp(double value, double minVal, double maxVal);
double lerp(double a, double b, double t);
double degToRad(double degrees);
double radToDeg(double radians);

} // namespace math
} // namespace ninja

#endif // MATH_FUNCTIONS_H
'@

Commit-As -Author 'dave' -Message 'Add math_functions module: factorial, fibonacci, statistics' -Date '2025-06-24T09:00:00.000000Z'

# --- r22: eve - matrix モジュール追加 ---
Add-File -RelPath 'src/matrix.cpp' -Content @'
#include "matrix.h"
#include <stdexcept>
#include <cmath>
#include <iomanip>
#include <sstream>

namespace ninja {

Matrix::Matrix(size_t rows, size_t cols)
    : rows_(rows), cols_(cols), data_(rows * cols, 0.0) {}

Matrix::Matrix(size_t rows, size_t cols, const std::vector<double>& data)
    : rows_(rows), cols_(cols), data_(data) {
    if (data.size() != rows * cols) {
        throw std::invalid_argument("Data size mismatch");
    }
}

double& Matrix::at(size_t row, size_t col) {
    if (row >= rows_ || col >= cols_) throw std::out_of_range("Index out of range");
    return data_[row * cols_ + col];
}

double Matrix::at(size_t row, size_t col) const {
    if (row >= rows_ || col >= cols_) throw std::out_of_range("Index out of range");
    return data_[row * cols_ + col];
}

Matrix Matrix::operator+(const Matrix& other) const {
    if (rows_ != other.rows_ || cols_ != other.cols_) {
        throw std::invalid_argument("Matrix dimensions mismatch for addition");
    }
    Matrix result(rows_, cols_);
    for (size_t i = 0; i < data_.size(); ++i) {
        result.data_[i] = data_[i] + other.data_[i];
    }
    return result;
}

Matrix Matrix::operator-(const Matrix& other) const {
    if (rows_ != other.rows_ || cols_ != other.cols_) {
        throw std::invalid_argument("Matrix dimensions mismatch for subtraction");
    }
    Matrix result(rows_, cols_);
    for (size_t i = 0; i < data_.size(); ++i) {
        result.data_[i] = data_[i] - other.data_[i];
    }
    return result;
}

Matrix Matrix::operator*(const Matrix& other) const {
    if (cols_ != other.rows_) {
        throw std::invalid_argument("Matrix dimensions mismatch for multiplication");
    }
    Matrix result(rows_, other.cols_);
    for (size_t i = 0; i < rows_; ++i) {
        for (size_t j = 0; j < other.cols_; ++j) {
            double sum = 0.0;
            for (size_t k = 0; k < cols_; ++k) {
                sum += at(i, k) * other.at(k, j);
            }
            result.at(i, j) = sum;
        }
    }
    return result;
}

Matrix Matrix::operator*(double scalar) const {
    Matrix result(rows_, cols_);
    for (size_t i = 0; i < data_.size(); ++i) {
        result.data_[i] = data_[i] * scalar;
    }
    return result;
}

Matrix Matrix::transpose() const {
    Matrix result(cols_, rows_);
    for (size_t i = 0; i < rows_; ++i) {
        for (size_t j = 0; j < cols_; ++j) {
            result.at(j, i) = at(i, j);
        }
    }
    return result;
}

double Matrix::determinant() const {
    if (rows_ != cols_) throw std::invalid_argument("Non-square matrix");
    if (rows_ == 1) return data_[0];
    if (rows_ == 2) return data_[0] * data_[3] - data_[1] * data_[2];
    double det = 0.0;
    for (size_t j = 0; j < cols_; ++j) {
        Matrix sub = submatrix(0, j);
        double sign = (j % 2 == 0) ? 1.0 : -1.0;
        det += sign * data_[j] * sub.determinant();
    }
    return det;
}

Matrix Matrix::submatrix(size_t excludeRow, size_t excludeCol) const {
    Matrix result(rows_ - 1, cols_ - 1);
    size_t ri = 0;
    for (size_t i = 0; i < rows_; ++i) {
        if (i == excludeRow) continue;
        size_t ci = 0;
        for (size_t j = 0; j < cols_; ++j) {
            if (j == excludeCol) continue;
            result.at(ri, ci) = at(i, j);
            ++ci;
        }
        ++ri;
    }
    return result;
}

Matrix Matrix::identity(size_t n) {
    Matrix result(n, n);
    for (size_t i = 0; i < n; ++i) {
        result.at(i, i) = 1.0;
    }
    return result;
}

std::string Matrix::toString() const {
    std::ostringstream oss;
    for (size_t i = 0; i < rows_; ++i) {
        oss << "| ";
        for (size_t j = 0; j < cols_; ++j) {
            oss << std::setw(8) << std::setprecision(4) << at(i, j) << " ";
        }
        oss << "|" << std::endl;
    }
    return oss.str();
}

bool Matrix::operator==(const Matrix& other) const {
    if (rows_ != other.rows_ || cols_ != other.cols_) return false;
    for (size_t i = 0; i < data_.size(); ++i) {
        if (std::abs(data_[i] - other.data_[i]) > 1e-9) return false;
    }
    return true;
}

double Matrix::trace() const {
    if (rows_ != cols_) throw std::invalid_argument("Non-square matrix");
    double sum = 0.0;
    for (size_t i = 0; i < rows_; ++i) {
        sum += at(i, i);
    }
    return sum;
}

double Matrix::norm() const {
    double sum = 0.0;
    for (double v : data_) {
        sum += v * v;
    }
    return std::sqrt(sum);
}

} // namespace ninja
'@

Add-File -RelPath 'include/matrix.h' -Content @'
#ifndef MATRIX_H
#define MATRIX_H

#include <vector>
#include <string>
#include <cstddef>

namespace ninja {

class Matrix {
public:
    Matrix(size_t rows, size_t cols);
    Matrix(size_t rows, size_t cols, const std::vector<double>& data);

    double& at(size_t row, size_t col);
    double at(size_t row, size_t col) const;

    size_t rows() const { return rows_; }
    size_t cols() const { return cols_; }

    Matrix operator+(const Matrix& other) const;
    Matrix operator-(const Matrix& other) const;
    Matrix operator*(const Matrix& other) const;
    Matrix operator*(double scalar) const;
    bool operator==(const Matrix& other) const;

    Matrix transpose() const;
    double determinant() const;
    Matrix submatrix(size_t excludeRow, size_t excludeCol) const;
    double trace() const;
    double norm() const;
    std::string toString() const;

    static Matrix identity(size_t n);

private:
    size_t rows_;
    size_t cols_;
    std::vector<double> data_;
};

} // namespace ninja

#endif // MATRIX_H
'@

Commit-As -Author 'eve' -Message 'Add Matrix class with full linear algebra support' -Date '2025-06-25T10:00:00.000000Z'

# --- r23: dave - config モジュール追加 ---
Add-File -RelPath 'src/config.cpp' -Content @'
#include "config.h"
#include <fstream>
#include <sstream>
#include <algorithm>
#include <stdexcept>
#include <iostream>

namespace ninja {

Config& Config::instance() {
    static Config config;
    return config;
}

void Config::load(const std::string& filename) {
    std::ifstream file(filename);
    if (!file.is_open()) {
        throw std::runtime_error("Cannot open config file: " + filename);
    }
    std::string line;
    std::string currentSection;
    while (std::getline(file, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#' || line[0] == ';') continue;
        if (line[0] == '[' && line.back() == ']') {
            currentSection = line.substr(1, line.size() - 2);
            continue;
        }
        auto eqPos = line.find('=');
        if (eqPos == std::string::npos) continue;
        std::string key = trim(line.substr(0, eqPos));
        std::string value = trim(line.substr(eqPos + 1));
        if (!currentSection.empty()) {
            key = currentSection + "." + key;
        }
        values_[key] = value;
    }
    filename_ = filename;
}

void Config::save(const std::string& filename) const {
    std::ofstream file(filename.empty() ? filename_ : filename);
    if (!file.is_open()) {
        throw std::runtime_error("Cannot write config file");
    }
    for (const auto& pair : values_) {
        file << pair.first << " = " << pair.second << std::endl;
    }
}

std::string Config::getString(const std::string& key, const std::string& defaultValue) const {
    auto it = values_.find(key);
    return (it != values_.end()) ? it->second : defaultValue;
}

int Config::getInt(const std::string& key, int defaultValue) const {
    auto it = values_.find(key);
    if (it == values_.end()) return defaultValue;
    try {
        return std::stoi(it->second);
    } catch (...) {
        return defaultValue;
    }
}

double Config::getDouble(const std::string& key, double defaultValue) const {
    auto it = values_.find(key);
    if (it == values_.end()) return defaultValue;
    try {
        return std::stod(it->second);
    } catch (...) {
        return defaultValue;
    }
}

bool Config::getBool(const std::string& key, bool defaultValue) const {
    auto it = values_.find(key);
    if (it == values_.end()) return defaultValue;
    std::string val = it->second;
    std::transform(val.begin(), val.end(), val.begin(), ::tolower);
    return val == "true" || val == "1" || val == "yes" || val == "on";
}

void Config::set(const std::string& key, const std::string& value) {
    values_[key] = value;
}

bool Config::hasKey(const std::string& key) const {
    return values_.find(key) != values_.end();
}

void Config::remove(const std::string& key) {
    values_.erase(key);
}

std::vector<std::string> Config::keys() const {
    std::vector<std::string> result;
    for (const auto& pair : values_) {
        result.push_back(pair.first);
    }
    return result;
}

void Config::clear() {
    values_.clear();
}

std::string Config::trim(const std::string& str) const {
    auto start = str.find_first_not_of(" \t");
    if (start == std::string::npos) return "";
    auto end = str.find_last_not_of(" \t");
    return str.substr(start, end - start + 1);
}

} // namespace ninja
'@

Add-File -RelPath 'include/config.h' -Content @'
#ifndef CONFIG_H
#define CONFIG_H

#include <string>
#include <map>
#include <vector>

namespace ninja {

class Config {
public:
    static Config& instance();

    void load(const std::string& filename);
    void save(const std::string& filename = "") const;

    std::string getString(const std::string& key, const std::string& defaultValue = "") const;
    int getInt(const std::string& key, int defaultValue = 0) const;
    double getDouble(const std::string& key, double defaultValue = 0.0) const;
    bool getBool(const std::string& key, bool defaultValue = false) const;

    void set(const std::string& key, const std::string& value);
    bool hasKey(const std::string& key) const;
    void remove(const std::string& key);
    std::vector<std::string> keys() const;
    void clear();

private:
    Config() = default;
    std::string trim(const std::string& str) const;
    std::map<std::string, std::string> values_;
    std::string filename_;
};

} // namespace ninja

#endif // CONFIG_H
'@

Commit-As -Author 'dave' -Message 'Add Config class for INI-style configuration' -Date '2025-06-26T11:00:00.000000Z'

# --- r24: eve - complex_number モジュール追加 ---
Add-File -RelPath 'src/complex_number.cpp' -Content @'
#include "complex_number.h"
#include <cmath>
#include <sstream>
#include <iomanip>
#include <stdexcept>

namespace ninja {

Complex::Complex(double real, double imag) : real_(real), imag_(imag) {}

Complex Complex::fromPolar(double r, double theta) {
    return Complex(r * std::cos(theta), r * std::sin(theta));
}

Complex Complex::operator+(const Complex& other) const {
    return Complex(real_ + other.real_, imag_ + other.imag_);
}

Complex Complex::operator-(const Complex& other) const {
    return Complex(real_ - other.real_, imag_ - other.imag_);
}

Complex Complex::operator*(const Complex& other) const {
    return Complex(
        real_ * other.real_ - imag_ * other.imag_,
        real_ * other.imag_ + imag_ * other.real_
    );
}

Complex Complex::operator/(const Complex& other) const {
    double denom = other.real_ * other.real_ + other.imag_ * other.imag_;
    if (denom == 0.0) throw std::runtime_error("Division by zero in complex division");
    return Complex(
        (real_ * other.real_ + imag_ * other.imag_) / denom,
        (imag_ * other.real_ - real_ * other.imag_) / denom
    );
}

bool Complex::operator==(const Complex& other) const {
    return std::abs(real_ - other.real_) < 1e-9 &&
           std::abs(imag_ - other.imag_) < 1e-9;
}

Complex Complex::conjugate() const {
    return Complex(real_, -imag_);
}

double Complex::magnitude() const {
    return std::sqrt(real_ * real_ + imag_ * imag_);
}

double Complex::phase() const {
    return std::atan2(imag_, real_);
}

Complex Complex::sqrt() const {
    double r = magnitude();
    double theta = phase();
    return fromPolar(std::sqrt(r), theta / 2.0);
}

Complex Complex::exp() const {
    double expReal = std::exp(real_);
    return Complex(expReal * std::cos(imag_), expReal * std::sin(imag_));
}

Complex Complex::log() const {
    return Complex(std::log(magnitude()), phase());
}

Complex Complex::pow(double n) const {
    double r = magnitude();
    double theta = phase();
    double newR = std::pow(r, n);
    return fromPolar(newR, n * theta);
}

std::string Complex::toString() const {
    std::ostringstream oss;
    oss << std::setprecision(6);
    if (imag_ >= 0) {
        oss << real_ << " + " << imag_ << "i";
    } else {
        oss << real_ << " - " << (-imag_) << "i";
    }
    return oss.str();
}

} // namespace ninja
'@

Add-File -RelPath 'include/complex_number.h' -Content @'
#ifndef COMPLEX_NUMBER_H
#define COMPLEX_NUMBER_H

#include <string>

namespace ninja {

class Complex {
public:
    Complex(double real = 0.0, double imag = 0.0);
    static Complex fromPolar(double r, double theta);

    double real() const { return real_; }
    double imag() const { return imag_; }

    Complex operator+(const Complex& other) const;
    Complex operator-(const Complex& other) const;
    Complex operator*(const Complex& other) const;
    Complex operator/(const Complex& other) const;
    bool operator==(const Complex& other) const;

    Complex conjugate() const;
    double magnitude() const;
    double phase() const;
    Complex sqrt() const;
    Complex exp() const;
    Complex log() const;
    Complex pow(double n) const;

    std::string toString() const;

private:
    double real_;
    double imag_;
};

} // namespace ninja

#endif // COMPLEX_NUMBER_H
'@

Commit-As -Author 'eve' -Message 'Add Complex number class with polar and exponential operations' -Date '2025-06-27T14:00:00.000000Z'

# --- r25: alice - expression_tree モジュール追加 ---
Add-File -RelPath 'src/expression_tree.cpp' -Content @'
#include "expression_tree.h"
#include <stdexcept>
#include <sstream>
#include <cmath>

namespace ninja {

ExprNode::ExprNode(double value) : type_(NodeType::NUMBER), value_(value) {}

ExprNode::ExprNode(NodeType type, ExprNodePtr left, ExprNodePtr right)
    : type_(type), value_(0), left_(std::move(left)), right_(std::move(right)) {}

double ExprNode::evaluate() const {
    switch (type_) {
        case NodeType::NUMBER:
            return value_;
        case NodeType::ADD:
            return left_->evaluate() + right_->evaluate();
        case NodeType::SUBTRACT:
            return left_->evaluate() - right_->evaluate();
        case NodeType::MULTIPLY:
            return left_->evaluate() * right_->evaluate();
        case NodeType::DIVIDE: {
            double divisor = right_->evaluate();
            if (divisor == 0.0) throw std::runtime_error("Division by zero");
            return left_->evaluate() / divisor;
        }
        case NodeType::MODULO: {
            double divisor = right_->evaluate();
            if (divisor == 0.0) throw std::runtime_error("Modulo by zero");
            return std::fmod(left_->evaluate(), divisor);
        }
        case NodeType::POWER:
            return std::pow(left_->evaluate(), right_->evaluate());
        case NodeType::NEGATE:
            return -left_->evaluate();
        default:
            throw std::runtime_error("Unknown node type");
    }
}

std::string ExprNode::toString() const {
    switch (type_) {
        case NodeType::NUMBER: {
            std::ostringstream oss;
            oss << value_;
            return oss.str();
        }
        case NodeType::ADD:
            return "(" + left_->toString() + " + " + right_->toString() + ")";
        case NodeType::SUBTRACT:
            return "(" + left_->toString() + " - " + right_->toString() + ")";
        case NodeType::MULTIPLY:
            return "(" + left_->toString() + " * " + right_->toString() + ")";
        case NodeType::DIVIDE:
            return "(" + left_->toString() + " / " + right_->toString() + ")";
        case NodeType::MODULO:
            return "(" + left_->toString() + " % " + right_->toString() + ")";
        case NodeType::POWER:
            return "(" + left_->toString() + " ^ " + right_->toString() + ")";
        case NodeType::NEGATE:
            return "(-" + left_->toString() + ")";
        default:
            return "?";
    }
}

size_t ExprNode::depth() const {
    if (type_ == NodeType::NUMBER) return 0;
    size_t leftDepth = left_ ? left_->depth() : 0;
    size_t rightDepth = right_ ? right_->depth() : 0;
    return 1 + std::max(leftDepth, rightDepth);
}

size_t ExprNode::nodeCount() const {
    size_t count = 1;
    if (left_) count += left_->nodeCount();
    if (right_) count += right_->nodeCount();
    return count;
}

ExprNodePtr ExprNode::simplify() const {
    if (type_ == NodeType::NUMBER) {
        return std::make_shared<ExprNode>(value_);
    }
    ExprNodePtr newLeft = left_ ? left_->simplify() : nullptr;
    ExprNodePtr newRight = right_ ? right_->simplify() : nullptr;
    // Constant folding
    if (newLeft && newLeft->type_ == NodeType::NUMBER &&
        newRight && newRight->type_ == NodeType::NUMBER) {
        ExprNode temp(type_, newLeft, newRight);
        return std::make_shared<ExprNode>(temp.evaluate());
    }
    // Identity: x + 0 = x, x * 1 = x
    if (type_ == NodeType::ADD && newRight && newRight->type_ == NodeType::NUMBER && newRight->value_ == 0.0) {
        return newLeft;
    }
    if (type_ == NodeType::MULTIPLY && newRight && newRight->type_ == NodeType::NUMBER && newRight->value_ == 1.0) {
        return newLeft;
    }
    // Zero: x * 0 = 0
    if (type_ == NodeType::MULTIPLY && newRight && newRight->type_ == NodeType::NUMBER && newRight->value_ == 0.0) {
        return std::make_shared<ExprNode>(0.0);
    }
    return std::make_shared<ExprNode>(type_, newLeft, newRight);
}

} // namespace ninja
'@

Add-File -RelPath 'include/expression_tree.h' -Content @'
#ifndef EXPRESSION_TREE_H
#define EXPRESSION_TREE_H

#include <memory>
#include <string>

namespace ninja {

class ExprNode;
using ExprNodePtr = std::shared_ptr<ExprNode>;

class ExprNode {
public:
    enum class NodeType {
        NUMBER, ADD, SUBTRACT, MULTIPLY, DIVIDE, MODULO, POWER, NEGATE
    };

    explicit ExprNode(double value);
    ExprNode(NodeType type, ExprNodePtr left, ExprNodePtr right = nullptr);

    double evaluate() const;
    std::string toString() const;
    size_t depth() const;
    size_t nodeCount() const;
    ExprNodePtr simplify() const;

    NodeType type() const { return type_; }

private:
    NodeType type_;
    double value_;
    ExprNodePtr left_;
    ExprNodePtr right_;
};

} // namespace ninja

#endif // EXPRESSION_TREE_H
'@

Commit-As -Author 'alice' -Message 'Add expression tree with simplification and constant folding' -Date '2025-06-28T09:00:00.000000Z'

# --- r26: bob - tokenizer モジュール追加 ---
Add-File -RelPath 'src/tokenizer.cpp' -Content @'
#include "tokenizer.h"
#include <cctype>
#include <stdexcept>
#include <sstream>
#include <algorithm>

namespace ninja {

Tokenizer::Tokenizer() {}

std::vector<Token2> Tokenizer::tokenize(const std::string& input) {
    std::vector<Token2> tokens;
    pos_ = 0;
    input_ = input;
    while (pos_ < input_.size()) {
        skipWhitespace();
        if (pos_ >= input_.size()) break;
        char c = input_[pos_];
        if (std::isdigit(c) || c == '.') {
            tokens.push_back(readNumber());
        } else if (std::isalpha(c) || c == '_') {
            tokens.push_back(readIdentifier());
        } else {
            tokens.push_back(readOperator());
        }
    }
    tokens.push_back({TokenType2::END_OF_INPUT, "", 0.0, pos_});
    return tokens;
}

void Tokenizer::skipWhitespace() {
    while (pos_ < input_.size() && std::isspace(input_[pos_])) {
        ++pos_;
    }
}

Token2 Tokenizer::readNumber() {
    size_t start = pos_;
    std::string num;
    bool hasDot = false;
    bool hasExp = false;
    while (pos_ < input_.size()) {
        char c = input_[pos_];
        if (std::isdigit(c)) {
            num += c;
            ++pos_;
        } else if (c == '.' && !hasDot && !hasExp) {
            hasDot = true;
            num += c;
            ++pos_;
        } else if ((c == 'e' || c == 'E') && !hasExp) {
            hasExp = true;
            num += c;
            ++pos_;
            if (pos_ < input_.size() && (input_[pos_] == '+' || input_[pos_] == '-')) {
                num += input_[pos_++];
            }
        } else {
            break;
        }
    }
    return {TokenType2::NUMBER, num, std::stod(num), start};
}

Token2 Tokenizer::readIdentifier() {
    size_t start = pos_;
    std::string ident;
    while (pos_ < input_.size() && (std::isalnum(input_[pos_]) || input_[pos_] == '_')) {
        ident += input_[pos_++];
    }
    // Check for known functions
    std::string lower = ident;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    TokenType2 type = TokenType2::IDENTIFIER;
    if (lower == "sin" || lower == "cos" || lower == "tan" ||
        lower == "sqrt" || lower == "abs" || lower == "log" ||
        lower == "exp" || lower == "floor" || lower == "ceil" ||
        lower == "round" || lower == "asin" || lower == "acos" ||
        lower == "atan" || lower == "sinh" || lower == "cosh" ||
        lower == "tanh") {
        type = TokenType2::FUNCTION;
    } else if (lower == "pi" || lower == "e") {
        type = TokenType2::CONSTANT;
    }
    return {type, ident, 0.0, start};
}

Token2 Tokenizer::readOperator() {
    size_t start = pos_;
    char c = input_[pos_++];
    TokenType2 type;
    switch (c) {
        case '+': type = TokenType2::PLUS; break;
        case '-': type = TokenType2::MINUS; break;
        case '*':
            if (pos_ < input_.size() && input_[pos_] == '*') {
                ++pos_;
                return {TokenType2::POWER, "**", 0.0, start};
            }
            type = TokenType2::MULTIPLY;
            break;
        case '/': type = TokenType2::DIVIDE; break;
        case '%': type = TokenType2::MODULO; break;
        case '^': type = TokenType2::POWER; break;
        case '(': type = TokenType2::LPAREN; break;
        case ')': type = TokenType2::RPAREN; break;
        case ',': type = TokenType2::COMMA; break;
        case '!': type = TokenType2::FACTORIAL; break;
        default:
            throw std::runtime_error(std::string("Unknown character: ") + c);
    }
    return {type, std::string(1, c), 0.0, start};
}

} // namespace ninja
'@

Add-File -RelPath 'include/tokenizer.h' -Content @'
#ifndef TOKENIZER_H
#define TOKENIZER_H

#include <string>
#include <vector>
#include <cstddef>

namespace ninja {

enum class TokenType2 {
    NUMBER, IDENTIFIER, FUNCTION, CONSTANT,
    PLUS, MINUS, MULTIPLY, DIVIDE, MODULO, POWER,
    LPAREN, RPAREN, COMMA, FACTORIAL,
    END_OF_INPUT
};

struct Token2 {
    TokenType2 type;
    std::string text;
    double value;
    size_t position;
};

class Tokenizer {
public:
    Tokenizer();
    std::vector<Token2> tokenize(const std::string& input);

private:
    void skipWhitespace();
    Token2 readNumber();
    Token2 readIdentifier();
    Token2 readOperator();

    std::string input_;
    size_t pos_;
};

} // namespace ninja

#endif // TOKENIZER_H
'@

Commit-As -Author 'bob' -Message 'Add advanced Tokenizer with function and constant support' -Date '2025-06-29T10:30:00.000000Z'

# --- r27: charlie - bigint モジュール追加 ---
Add-File -RelPath 'src/bigint.cpp' -Content @'
#include "bigint.h"
#include <algorithm>
#include <stdexcept>
#include <sstream>
#include <cctype>
#include <cmath>

namespace ninja {

BigInt::BigInt() : negative_(false), digits_{0} {}

BigInt::BigInt(long long val) : negative_(val < 0) {
    if (val < 0) val = -val;
    if (val == 0) { digits_.push_back(0); return; }
    while (val > 0) {
        digits_.push_back(static_cast<int>(val % 10));
        val /= 10;
    }
}

BigInt::BigInt(const std::string& str) : negative_(false) {
    if (str.empty()) throw std::invalid_argument("Empty string");
    size_t start = 0;
    if (str[0] == '-') { negative_ = true; start = 1; }
    else if (str[0] == '+') { start = 1; }
    for (size_t i = str.size(); i > start; --i) {
        if (!std::isdigit(str[i-1])) throw std::invalid_argument("Non-digit character");
        digits_.push_back(str[i-1] - '0');
    }
    trimLeadingZeros();
    if (isZero()) negative_ = false;
}

BigInt BigInt::operator+(const BigInt& other) const {
    if (negative_ == other.negative_) {
        BigInt result = addAbsolute(*this, other);
        result.negative_ = negative_;
        return result;
    }
    if (compareAbsolute(*this, other) >= 0) {
        BigInt result = subtractAbsolute(*this, other);
        result.negative_ = negative_;
        if (result.isZero()) result.negative_ = false;
        return result;
    }
    BigInt result = subtractAbsolute(other, *this);
    result.negative_ = other.negative_;
    if (result.isZero()) result.negative_ = false;
    return result;
}

BigInt BigInt::operator-(const BigInt& other) const {
    BigInt neg = other;
    neg.negative_ = !neg.negative_;
    if (neg.isZero()) neg.negative_ = false;
    return *this + neg;
}

BigInt BigInt::operator*(const BigInt& other) const {
    BigInt result;
    result.digits_.resize(digits_.size() + other.digits_.size(), 0);
    for (size_t i = 0; i < digits_.size(); ++i) {
        int carry = 0;
        for (size_t j = 0; j < other.digits_.size() || carry; ++j) {
            long long cur = result.digits_[i + j] +
                           carry +
                           (j < other.digits_.size() ? static_cast<long long>(digits_[i]) * other.digits_[j] : 0);
            result.digits_[i + j] = static_cast<int>(cur % 10);
            carry = static_cast<int>(cur / 10);
        }
    }
    result.negative_ = negative_ != other.negative_;
    result.trimLeadingZeros();
    if (result.isZero()) result.negative_ = false;
    return result;
}

bool BigInt::operator==(const BigInt& other) const {
    return negative_ == other.negative_ && digits_ == other.digits_;
}

bool BigInt::operator!=(const BigInt& other) const {
    return !(*this == other);
}

bool BigInt::operator<(const BigInt& other) const {
    if (negative_ != other.negative_) return negative_;
    int cmp = compareAbsolute(*this, other);
    return negative_ ? (cmp > 0) : (cmp < 0);
}

bool BigInt::operator>(const BigInt& other) const {
    return other < *this;
}

bool BigInt::operator<=(const BigInt& other) const {
    return !(other < *this);
}

bool BigInt::operator>=(const BigInt& other) const {
    return !(*this < other);
}

bool BigInt::isZero() const {
    return digits_.size() == 1 && digits_[0] == 0;
}

BigInt BigInt::abs() const {
    BigInt result = *this;
    result.negative_ = false;
    return result;
}

std::string BigInt::toString() const {
    std::string result;
    if (negative_) result += '-';
    for (auto it = digits_.rbegin(); it != digits_.rend(); ++it) {
        result += ('0' + *it);
    }
    return result;
}

size_t BigInt::digitCount() const {
    return digits_.size();
}

BigInt BigInt::addAbsolute(const BigInt& a, const BigInt& b) {
    BigInt result;
    result.digits_.clear();
    int carry = 0;
    size_t maxLen = std::max(a.digits_.size(), b.digits_.size());
    for (size_t i = 0; i < maxLen || carry; ++i) {
        int sum = carry;
        if (i < a.digits_.size()) sum += a.digits_[i];
        if (i < b.digits_.size()) sum += b.digits_[i];
        result.digits_.push_back(sum % 10);
        carry = sum / 10;
    }
    return result;
}

BigInt BigInt::subtractAbsolute(const BigInt& a, const BigInt& b) {
    BigInt result;
    result.digits_.clear();
    int borrow = 0;
    for (size_t i = 0; i < a.digits_.size(); ++i) {
        int diff = a.digits_[i] - borrow - (i < b.digits_.size() ? b.digits_[i] : 0);
        if (diff < 0) { diff += 10; borrow = 1; } else { borrow = 0; }
        result.digits_.push_back(diff);
    }
    result.trimLeadingZeros();
    return result;
}

int BigInt::compareAbsolute(const BigInt& a, const BigInt& b) {
    if (a.digits_.size() != b.digits_.size())
        return a.digits_.size() > b.digits_.size() ? 1 : -1;
    for (size_t i = a.digits_.size(); i > 0; --i) {
        if (a.digits_[i-1] != b.digits_[i-1])
            return a.digits_[i-1] > b.digits_[i-1] ? 1 : -1;
    }
    return 0;
}

void BigInt::trimLeadingZeros() {
    while (digits_.size() > 1 && digits_.back() == 0) {
        digits_.pop_back();
    }
}

} // namespace ninja
'@

Add-File -RelPath 'include/bigint.h' -Content @'
#ifndef BIGINT_H
#define BIGINT_H

#include <string>
#include <vector>
#include <cstddef>

namespace ninja {

class BigInt {
public:
    BigInt();
    BigInt(long long val);
    explicit BigInt(const std::string& str);

    BigInt operator+(const BigInt& other) const;
    BigInt operator-(const BigInt& other) const;
    BigInt operator*(const BigInt& other) const;

    bool operator==(const BigInt& other) const;
    bool operator!=(const BigInt& other) const;
    bool operator<(const BigInt& other) const;
    bool operator>(const BigInt& other) const;
    bool operator<=(const BigInt& other) const;
    bool operator>=(const BigInt& other) const;

    bool isZero() const;
    BigInt abs() const;
    std::string toString() const;
    size_t digitCount() const;

private:
    bool negative_;
    std::vector<int> digits_;

    static BigInt addAbsolute(const BigInt& a, const BigInt& b);
    static BigInt subtractAbsolute(const BigInt& a, const BigInt& b);
    static int compareAbsolute(const BigInt& a, const BigInt& b);
    void trimLeadingZeros();
};

} // namespace ninja

#endif // BIGINT_H
'@

Commit-As -Author 'charlie' -Message 'Add BigInt class for arbitrary precision integer arithmetic' -Date '2025-06-30T13:00:00.000000Z'

# --- r28: dave - graph モジュール追加 ---
Add-File -RelPath 'src/graph.cpp' -Content @'
#include "graph.h"
#include <queue>
#include <stack>
#include <algorithm>
#include <stdexcept>
#include <limits>
#include <sstream>

namespace ninja {

Graph::Graph(size_t vertices) : adjList_(vertices) {}

void Graph::addEdge(size_t from, size_t to, double weight) {
    if (from >= adjList_.size() || to >= adjList_.size()) {
        throw std::out_of_range("Vertex index out of range");
    }
    adjList_[from].push_back({to, weight});
}

void Graph::addUndirectedEdge(size_t u, size_t v, double weight) {
    addEdge(u, v, weight);
    addEdge(v, u, weight);
}

std::vector<size_t> Graph::bfs(size_t start) const {
    std::vector<size_t> order;
    std::vector<bool> visited(adjList_.size(), false);
    std::queue<size_t> q;
    visited[start] = true;
    q.push(start);
    while (!q.empty()) {
        size_t v = q.front();
        q.pop();
        order.push_back(v);
        for (const auto& edge : adjList_[v]) {
            if (!visited[edge.to]) {
                visited[edge.to] = true;
                q.push(edge.to);
            }
        }
    }
    return order;
}

std::vector<size_t> Graph::dfs(size_t start) const {
    std::vector<size_t> order;
    std::vector<bool> visited(adjList_.size(), false);
    std::stack<size_t> s;
    s.push(start);
    while (!s.empty()) {
        size_t v = s.top();
        s.pop();
        if (visited[v]) continue;
        visited[v] = true;
        order.push_back(v);
        for (auto it = adjList_[v].rbegin(); it != adjList_[v].rend(); ++it) {
            if (!visited[it->to]) {
                s.push(it->to);
            }
        }
    }
    return order;
}

std::vector<double> Graph::dijkstra(size_t start) const {
    size_t n = adjList_.size();
    std::vector<double> dist(n, std::numeric_limits<double>::infinity());
    dist[start] = 0.0;
    using PairDV = std::pair<double, size_t>;
    std::priority_queue<PairDV, std::vector<PairDV>, std::greater<PairDV>> pq;
    pq.push({0.0, start});
    while (!pq.empty()) {
        auto [d, u] = pq.top();
        pq.pop();
        if (d > dist[u]) continue;
        for (const auto& edge : adjList_[u]) {
            double newDist = dist[u] + edge.weight;
            if (newDist < dist[edge.to]) {
                dist[edge.to] = newDist;
                pq.push({newDist, edge.to});
            }
        }
    }
    return dist;
}

bool Graph::hasCycle() const {
    size_t n = adjList_.size();
    std::vector<int> color(n, 0);
    for (size_t i = 0; i < n; ++i) {
        if (color[i] == 0 && hasCycleDfs(i, color)) {
            return true;
        }
    }
    return false;
}

bool Graph::hasCycleDfs(size_t v, std::vector<int>& color) const {
    color[v] = 1;
    for (const auto& edge : adjList_[v]) {
        if (color[edge.to] == 1) return true;
        if (color[edge.to] == 0 && hasCycleDfs(edge.to, color)) return true;
    }
    color[v] = 2;
    return false;
}

std::vector<size_t> Graph::topologicalSort() const {
    if (hasCycle()) throw std::runtime_error("Graph has a cycle");
    size_t n = adjList_.size();
    std::vector<bool> visited(n, false);
    std::vector<size_t> order;
    for (size_t i = 0; i < n; ++i) {
        if (!visited[i]) {
            topologicalSortDfs(i, visited, order);
        }
    }
    std::reverse(order.begin(), order.end());
    return order;
}

void Graph::topologicalSortDfs(size_t v, std::vector<bool>& visited,
                                std::vector<size_t>& order) const {
    visited[v] = true;
    for (const auto& edge : adjList_[v]) {
        if (!visited[edge.to]) {
            topologicalSortDfs(edge.to, visited, order);
        }
    }
    order.push_back(v);
}

size_t Graph::vertexCount() const {
    return adjList_.size();
}

size_t Graph::edgeCount() const {
    size_t count = 0;
    for (const auto& edges : adjList_) {
        count += edges.size();
    }
    return count;
}

std::string Graph::toString() const {
    std::ostringstream oss;
    for (size_t i = 0; i < adjList_.size(); ++i) {
        oss << i << ": ";
        for (const auto& edge : adjList_[i]) {
            oss << "(" << edge.to << ", w=" << edge.weight << ") ";
        }
        oss << std::endl;
    }
    return oss.str();
}

} // namespace ninja
'@

Add-File -RelPath 'include/graph.h' -Content @'
#ifndef GRAPH_H
#define GRAPH_H

#include <vector>
#include <string>
#include <cstddef>

namespace ninja {

struct Edge {
    size_t to;
    double weight;
};

class Graph {
public:
    explicit Graph(size_t vertices);

    void addEdge(size_t from, size_t to, double weight = 1.0);
    void addUndirectedEdge(size_t u, size_t v, double weight = 1.0);

    std::vector<size_t> bfs(size_t start) const;
    std::vector<size_t> dfs(size_t start) const;
    std::vector<double> dijkstra(size_t start) const;
    bool hasCycle() const;
    std::vector<size_t> topologicalSort() const;

    size_t vertexCount() const;
    size_t edgeCount() const;
    std::string toString() const;

private:
    std::vector<std::vector<Edge>> adjList_;
    bool hasCycleDfs(size_t v, std::vector<int>& color) const;
    void topologicalSortDfs(size_t v, std::vector<bool>& visited,
                            std::vector<size_t>& order) const;
};

} // namespace ninja

#endif // GRAPH_H
'@

Commit-As -Author 'dave' -Message 'Add Graph class: BFS, DFS, Dijkstra, topological sort' -Date '2025-07-01T09:30:00.000000Z'

# --- r29: eve - vector3d モジュール追加 ---
Add-File -RelPath 'src/vector3d.cpp' -Content @'
#include "vector3d.h"
#include <cmath>
#include <sstream>
#include <iomanip>
#include <stdexcept>

namespace ninja {

Vector3D::Vector3D(double x, double y, double z) : x_(x), y_(y), z_(z) {}

Vector3D Vector3D::operator+(const Vector3D& other) const {
    return Vector3D(x_ + other.x_, y_ + other.y_, z_ + other.z_);
}

Vector3D Vector3D::operator-(const Vector3D& other) const {
    return Vector3D(x_ - other.x_, y_ - other.y_, z_ - other.z_);
}

Vector3D Vector3D::operator*(double scalar) const {
    return Vector3D(x_ * scalar, y_ * scalar, z_ * scalar);
}

Vector3D Vector3D::operator/(double scalar) const {
    if (scalar == 0.0) throw std::runtime_error("Division by zero");
    return Vector3D(x_ / scalar, y_ / scalar, z_ / scalar);
}

bool Vector3D::operator==(const Vector3D& other) const {
    return std::abs(x_ - other.x_) < 1e-9 &&
           std::abs(y_ - other.y_) < 1e-9 &&
           std::abs(z_ - other.z_) < 1e-9;
}

double Vector3D::dot(const Vector3D& other) const {
    return x_ * other.x_ + y_ * other.y_ + z_ * other.z_;
}

Vector3D Vector3D::cross(const Vector3D& other) const {
    return Vector3D(
        y_ * other.z_ - z_ * other.y_,
        z_ * other.x_ - x_ * other.z_,
        x_ * other.y_ - y_ * other.x_
    );
}

double Vector3D::magnitude() const {
    return std::sqrt(x_ * x_ + y_ * y_ + z_ * z_);
}

Vector3D Vector3D::normalized() const {
    double mag = magnitude();
    if (mag == 0.0) throw std::runtime_error("Cannot normalize zero vector");
    return *this / mag;
}

double Vector3D::angleTo(const Vector3D& other) const {
    double dotProd = dot(other);
    double mags = magnitude() * other.magnitude();
    if (mags == 0.0) throw std::runtime_error("Zero vector in angle calculation");
    double cosAngle = dotProd / mags;
    cosAngle = std::max(-1.0, std::min(1.0, cosAngle));
    return std::acos(cosAngle);
}

double Vector3D::distanceTo(const Vector3D& other) const {
    return (*this - other).magnitude();
}

Vector3D Vector3D::project(const Vector3D& onto) const {
    double d = onto.dot(onto);
    if (d == 0.0) throw std::runtime_error("Cannot project onto zero vector");
    return onto * (dot(onto) / d);
}

Vector3D Vector3D::reflect(const Vector3D& normal) const {
    return *this - normal * (2.0 * dot(normal));
}

Vector3D Vector3D::lerp(const Vector3D& other, double t) const {
    return *this * (1.0 - t) + other * t;
}

std::string Vector3D::toString() const {
    std::ostringstream oss;
    oss << std::setprecision(6) << "(" << x_ << ", " << y_ << ", " << z_ << ")";
    return oss.str();
}

Vector3D Vector3D::zero() { return Vector3D(0, 0, 0); }
Vector3D Vector3D::unitX() { return Vector3D(1, 0, 0); }
Vector3D Vector3D::unitY() { return Vector3D(0, 1, 0); }
Vector3D Vector3D::unitZ() { return Vector3D(0, 0, 1); }

} // namespace ninja
'@

Add-File -RelPath 'include/vector3d.h' -Content @'
#ifndef VECTOR3D_H
#define VECTOR3D_H

#include <string>

namespace ninja {

class Vector3D {
public:
    Vector3D(double x = 0, double y = 0, double z = 0);

    double x() const { return x_; }
    double y() const { return y_; }
    double z() const { return z_; }

    Vector3D operator+(const Vector3D& other) const;
    Vector3D operator-(const Vector3D& other) const;
    Vector3D operator*(double scalar) const;
    Vector3D operator/(double scalar) const;
    bool operator==(const Vector3D& other) const;

    double dot(const Vector3D& other) const;
    Vector3D cross(const Vector3D& other) const;
    double magnitude() const;
    Vector3D normalized() const;
    double angleTo(const Vector3D& other) const;
    double distanceTo(const Vector3D& other) const;
    Vector3D project(const Vector3D& onto) const;
    Vector3D reflect(const Vector3D& normal) const;
    Vector3D lerp(const Vector3D& other, double t) const;

    std::string toString() const;

    static Vector3D zero();
    static Vector3D unitX();
    static Vector3D unitY();
    static Vector3D unitZ();

private:
    double x_, y_, z_;
};

} // namespace ninja

#endif // VECTOR3D_H
'@

Commit-As -Author 'eve' -Message 'Add Vector3D class with cross product, projection, reflection' -Date '2025-07-02T11:00:00.000000Z'

# --- r30: alice - signal_processor モジュール追加 ---
Add-File -RelPath 'src/signal_processor.cpp' -Content @'
#include "signal_processor.h"
#include <cmath>
#include <algorithm>
#include <numeric>
#include <stdexcept>

namespace ninja {

SignalProcessor::SignalProcessor(size_t sampleRate)
    : sampleRate_(sampleRate) {}

std::vector<double> SignalProcessor::generateSine(double frequency,
    double duration, double amplitude) const {
    size_t numSamples = static_cast<size_t>(sampleRate_ * duration);
    std::vector<double> signal(numSamples);
    double twoPiF = 2.0 * M_PI * frequency;
    for (size_t i = 0; i < numSamples; ++i) {
        double t = static_cast<double>(i) / sampleRate_;
        signal[i] = amplitude * std::sin(twoPiF * t);
    }
    return signal;
}

std::vector<double> SignalProcessor::generateSquare(double frequency,
    double duration, double amplitude) const {
    size_t numSamples = static_cast<size_t>(sampleRate_ * duration);
    std::vector<double> signal(numSamples);
    double period = sampleRate_ / frequency;
    for (size_t i = 0; i < numSamples; ++i) {
        double phase = std::fmod(static_cast<double>(i), period) / period;
        signal[i] = (phase < 0.5) ? amplitude : -amplitude;
    }
    return signal;
}

std::vector<double> SignalProcessor::lowPassFilter(
    const std::vector<double>& signal, double cutoffFreq) const {
    double rc = 1.0 / (2.0 * M_PI * cutoffFreq);
    double dt = 1.0 / sampleRate_;
    double alpha = dt / (rc + dt);
    std::vector<double> filtered(signal.size());
    filtered[0] = alpha * signal[0];
    for (size_t i = 1; i < signal.size(); ++i) {
        filtered[i] = filtered[i-1] + alpha * (signal[i] - filtered[i-1]);
    }
    return filtered;
}

std::vector<double> SignalProcessor::highPassFilter(
    const std::vector<double>& signal, double cutoffFreq) const {
    double rc = 1.0 / (2.0 * M_PI * cutoffFreq);
    double dt = 1.0 / sampleRate_;
    double alpha = rc / (rc + dt);
    std::vector<double> filtered(signal.size());
    filtered[0] = signal[0];
    for (size_t i = 1; i < signal.size(); ++i) {
        filtered[i] = alpha * (filtered[i-1] + signal[i] - signal[i-1]);
    }
    return filtered;
}

std::vector<double> SignalProcessor::movingAverage(
    const std::vector<double>& signal, size_t windowSize) const {
    if (windowSize == 0) throw std::invalid_argument("Window size must be positive");
    if (signal.size() < windowSize) return signal;
    std::vector<double> result(signal.size() - windowSize + 1);
    double sum = std::accumulate(signal.begin(), signal.begin() + windowSize, 0.0);
    result[0] = sum / windowSize;
    for (size_t i = 1; i < result.size(); ++i) {
        sum += signal[i + windowSize - 1] - signal[i - 1];
        result[i] = sum / windowSize;
    }
    return result;
}

double SignalProcessor::rms(const std::vector<double>& signal) const {
    if (signal.empty()) throw std::invalid_argument("Empty signal");
    double sumSq = 0.0;
    for (double s : signal) { sumSq += s * s; }
    return std::sqrt(sumSq / signal.size());
}

double SignalProcessor::peakToPeak(const std::vector<double>& signal) const {
    if (signal.empty()) throw std::invalid_argument("Empty signal");
    auto minmax = std::minmax_element(signal.begin(), signal.end());
    return *minmax.second - *minmax.first;
}

std::vector<double> SignalProcessor::normalize(
    const std::vector<double>& signal) const {
    if (signal.empty()) return signal;
    auto minmax = std::minmax_element(signal.begin(), signal.end());
    double range = *minmax.second - *minmax.first;
    if (range == 0.0) return std::vector<double>(signal.size(), 0.0);
    std::vector<double> result(signal.size());
    for (size_t i = 0; i < signal.size(); ++i) {
        result[i] = (signal[i] - *minmax.first) / range;
    }
    return result;
}

std::vector<double> SignalProcessor::convolve(
    const std::vector<double>& signal,
    const std::vector<double>& kernel) const {
    size_t outLen = signal.size() + kernel.size() - 1;
    std::vector<double> result(outLen, 0.0);
    for (size_t i = 0; i < signal.size(); ++i) {
        for (size_t j = 0; j < kernel.size(); ++j) {
            result[i + j] += signal[i] * kernel[j];
        }
    }
    return result;
}

} // namespace ninja
'@

Add-File -RelPath 'include/signal_processor.h' -Content @'
#ifndef SIGNAL_PROCESSOR_H
#define SIGNAL_PROCESSOR_H

#include <vector>
#include <cstddef>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace ninja {

class SignalProcessor {
public:
    explicit SignalProcessor(size_t sampleRate = 44100);

    std::vector<double> generateSine(double frequency, double duration,
        double amplitude = 1.0) const;
    std::vector<double> generateSquare(double frequency, double duration,
        double amplitude = 1.0) const;

    std::vector<double> lowPassFilter(const std::vector<double>& signal,
        double cutoffFreq) const;
    std::vector<double> highPassFilter(const std::vector<double>& signal,
        double cutoffFreq) const;
    std::vector<double> movingAverage(const std::vector<double>& signal,
        size_t windowSize) const;

    double rms(const std::vector<double>& signal) const;
    double peakToPeak(const std::vector<double>& signal) const;

    std::vector<double> normalize(const std::vector<double>& signal) const;
    std::vector<double> convolve(const std::vector<double>& signal,
        const std::vector<double>& kernel) const;

private:
    size_t sampleRate_;
};

} // namespace ninja

#endif // SIGNAL_PROCESSOR_H
'@

Commit-As -Author 'alice' -Message 'Add SignalProcessor with filters, generators, and analysis' -Date '2025-07-03T14:00:00.000000Z'

# --- r31-r40: 追加テストファイルと小さな新ファイル群 ---
# r31: bob - テストファイル群追加
Add-File -RelPath 'tests/test_math_functions.cpp' -Content @'
#include "math_functions.h"
#include <cassert>
#include <iostream>
#include <cmath>
#include <vector>

void testFactorial() {
    assert(std::abs(ninja::math::factorial(0) - 1.0) < 1e-9);
    assert(std::abs(ninja::math::factorial(5) - 120.0) < 1e-9);
    assert(std::abs(ninja::math::factorial(10) - 3628800.0) < 1e-9);
    std::cout << "PASS: testFactorial" << std::endl;
}

void testFibonacci() {
    assert(std::abs(ninja::math::fibonacci(0) - 0.0) < 1e-9);
    assert(std::abs(ninja::math::fibonacci(1) - 1.0) < 1e-9);
    assert(std::abs(ninja::math::fibonacci(10) - 55.0) < 1e-9);
    std::cout << "PASS: testFibonacci" << std::endl;
}

void testGcd() {
    assert(std::abs(ninja::math::gcd(12, 8) - 4.0) < 1e-9);
    assert(std::abs(ninja::math::gcd(100, 75) - 25.0) < 1e-9);
    std::cout << "PASS: testGcd" << std::endl;
}

void testMean() {
    std::vector<double> v = {1, 2, 3, 4, 5};
    assert(std::abs(ninja::math::mean(v) - 3.0) < 1e-9);
    std::cout << "PASS: testMean" << std::endl;
}

void testMedian() {
    std::vector<double> v1 = {1, 3, 5, 7, 9};
    assert(std::abs(ninja::math::median(v1) - 5.0) < 1e-9);
    std::vector<double> v2 = {1, 2, 3, 4};
    assert(std::abs(ninja::math::median(v2) - 2.5) < 1e-9);
    std::cout << "PASS: testMedian" << std::endl;
}

void testClamp() {
    assert(std::abs(ninja::math::clamp(5.0, 0.0, 10.0) - 5.0) < 1e-9);
    assert(std::abs(ninja::math::clamp(-1.0, 0.0, 10.0) - 0.0) < 1e-9);
    assert(std::abs(ninja::math::clamp(15.0, 0.0, 10.0) - 10.0) < 1e-9);
    std::cout << "PASS: testClamp" << std::endl;
}

int main() {
    testFactorial();
    testFibonacci();
    testGcd();
    testMean();
    testMedian();
    testClamp();
    std::cout << "All math function tests passed!" << std::endl;
    return 0;
}
'@

Add-File -RelPath 'tests/test_matrix.cpp' -Content @'
#include "matrix.h"
#include <cassert>
#include <iostream>
#include <cmath>

void testIdentity() {
    auto I = ninja::Matrix::identity(3);
    assert(std::abs(I.at(0,0) - 1.0) < 1e-9);
    assert(std::abs(I.at(1,1) - 1.0) < 1e-9);
    assert(std::abs(I.at(0,1) - 0.0) < 1e-9);
    std::cout << "PASS: testIdentity" << std::endl;
}

void testAddition() {
    ninja::Matrix a(2, 2, {1, 2, 3, 4});
    ninja::Matrix b(2, 2, {5, 6, 7, 8});
    ninja::Matrix c = a + b;
    assert(std::abs(c.at(0,0) - 6.0) < 1e-9);
    assert(std::abs(c.at(1,1) - 12.0) < 1e-9);
    std::cout << "PASS: testAddition" << std::endl;
}

void testMultiplication() {
    ninja::Matrix a(2, 2, {1, 2, 3, 4});
    ninja::Matrix b(2, 2, {5, 6, 7, 8});
    ninja::Matrix c = a * b;
    assert(std::abs(c.at(0,0) - 19.0) < 1e-9);
    assert(std::abs(c.at(0,1) - 22.0) < 1e-9);
    assert(std::abs(c.at(1,0) - 43.0) < 1e-9);
    assert(std::abs(c.at(1,1) - 50.0) < 1e-9);
    std::cout << "PASS: testMultiplication" << std::endl;
}

void testDeterminant() {
    ninja::Matrix m(2, 2, {1, 2, 3, 4});
    assert(std::abs(m.determinant() - (-2.0)) < 1e-9);
    std::cout << "PASS: testDeterminant" << std::endl;
}

void testTranspose() {
    ninja::Matrix m(2, 3, {1, 2, 3, 4, 5, 6});
    ninja::Matrix t = m.transpose();
    assert(t.rows() == 3 && t.cols() == 2);
    assert(std::abs(t.at(0,0) - 1.0) < 1e-9);
    assert(std::abs(t.at(2,1) - 6.0) < 1e-9);
    std::cout << "PASS: testTranspose" << std::endl;
}

int main() {
    testIdentity();
    testAddition();
    testMultiplication();
    testDeterminant();
    testTranspose();
    std::cout << "All matrix tests passed!" << std::endl;
    return 0;
}
'@

Commit-As -Author 'bob' -Message 'Add comprehensive tests for math_functions and matrix modules' -Date '2025-07-04T10:00:00.000000Z'

# r32: charlie - テストファイル群追加 (bigint, vector3d)
Add-File -RelPath 'tests/test_bigint.cpp' -Content @'
#include "bigint.h"
#include <cassert>
#include <iostream>

void testConstruction() {
    ninja::BigInt a(12345);
    assert(a.toString() == "12345");
    ninja::BigInt b("-98765");
    assert(b.toString() == "-98765");
    ninja::BigInt c(0);
    assert(c.toString() == "0");
    std::cout << "PASS: testConstruction" << std::endl;
}

void testAddition() {
    ninja::BigInt a(999);
    ninja::BigInt b(1);
    ninja::BigInt c = a + b;
    assert(c.toString() == "1000");
    ninja::BigInt d(-500);
    ninja::BigInt e = a + d;
    assert(e.toString() == "499");
    std::cout << "PASS: testAddition" << std::endl;
}

void testSubtraction() {
    ninja::BigInt a(1000);
    ninja::BigInt b(1);
    ninja::BigInt c = a - b;
    assert(c.toString() == "999");
    std::cout << "PASS: testSubtraction" << std::endl;
}

void testMultiplication() {
    ninja::BigInt a(123);
    ninja::BigInt b(456);
    ninja::BigInt c = a * b;
    assert(c.toString() == "56088");
    std::cout << "PASS: testMultiplication" << std::endl;
}

void testComparison() {
    ninja::BigInt a(100);
    ninja::BigInt b(200);
    assert(a < b);
    assert(b > a);
    assert(a != b);
    ninja::BigInt c(100);
    assert(a == c);
    std::cout << "PASS: testComparison" << std::endl;
}

int main() {
    testConstruction();
    testAddition();
    testSubtraction();
    testMultiplication();
    testComparison();
    std::cout << "All BigInt tests passed!" << std::endl;
    return 0;
}
'@

Add-File -RelPath 'tests/test_vector3d.cpp' -Content @'
#include "vector3d.h"
#include <cassert>
#include <iostream>
#include <cmath>

void testAddSub() {
    ninja::Vector3D a(1, 2, 3);
    ninja::Vector3D b(4, 5, 6);
    auto c = a + b;
    assert(c == ninja::Vector3D(5, 7, 9));
    auto d = b - a;
    assert(d == ninja::Vector3D(3, 3, 3));
    std::cout << "PASS: testAddSub" << std::endl;
}

void testDot() {
    ninja::Vector3D a(1, 0, 0);
    ninja::Vector3D b(0, 1, 0);
    assert(std::abs(a.dot(b)) < 1e-9);
    assert(std::abs(a.dot(a) - 1.0) < 1e-9);
    std::cout << "PASS: testDot" << std::endl;
}

void testCross() {
    auto c = ninja::Vector3D::unitX().cross(ninja::Vector3D::unitY());
    assert(c == ninja::Vector3D::unitZ());
    std::cout << "PASS: testCross" << std::endl;
}

void testMagnitude() {
    ninja::Vector3D v(3, 4, 0);
    assert(std::abs(v.magnitude() - 5.0) < 1e-9);
    std::cout << "PASS: testMagnitude" << std::endl;
}

void testNormalize() {
    ninja::Vector3D v(0, 3, 4);
    auto n = v.normalized();
    assert(std::abs(n.magnitude() - 1.0) < 1e-9);
    std::cout << "PASS: testNormalize" << std::endl;
}

int main() {
    testAddSub();
    testDot();
    testCross();
    testMagnitude();
    testNormalize();
    std::cout << "All Vector3D tests passed!" << std::endl;
    return 0;
}
'@

Commit-As -Author 'charlie' -Message 'Add tests for BigInt and Vector3D classes' -Date '2025-07-05T09:00:00.000000Z'

# r33-r40: 追加ソースファイル群を一括作成 (一度に複数ファイルを追加する co-change パターン)
# r33: dave - hash_map と linked_list
Add-File -RelPath 'src/hash_map.cpp' -Content @'
#include "hash_map.h"
#include <stdexcept>
#include <functional>

namespace ninja {

HashMap::HashMap(size_t bucketCount) : buckets_(bucketCount) {}

void HashMap::insert(const std::string& key, double value) {
    size_t idx = hash(key);
    for (auto& pair : buckets_[idx]) {
        if (pair.first == key) { pair.second = value; return; }
    }
    buckets_[idx].push_back({key, value});
    size_++;
}

double HashMap::get(const std::string& key) const {
    size_t idx = hash(key);
    for (const auto& pair : buckets_[idx]) {
        if (pair.first == key) return pair.second;
    }
    throw std::out_of_range("Key not found: " + key);
}

bool HashMap::contains(const std::string& key) const {
    size_t idx = hash(key);
    for (const auto& pair : buckets_[idx]) {
        if (pair.first == key) return true;
    }
    return false;
}

void HashMap::remove(const std::string& key) {
    size_t idx = hash(key);
    auto& bucket = buckets_[idx];
    for (auto it = bucket.begin(); it != bucket.end(); ++it) {
        if (it->first == key) { bucket.erase(it); size_--; return; }
    }
}

size_t HashMap::size() const { return size_; }

bool HashMap::empty() const { return size_ == 0; }

void HashMap::clear() {
    for (auto& bucket : buckets_) bucket.clear();
    size_ = 0;
}

std::vector<std::string> HashMap::keys() const {
    std::vector<std::string> result;
    for (const auto& bucket : buckets_) {
        for (const auto& pair : bucket) {
            result.push_back(pair.first);
        }
    }
    return result;
}

double HashMap::loadFactor() const {
    return static_cast<double>(size_) / buckets_.size();
}

size_t HashMap::hash(const std::string& key) const {
    return std::hash<std::string>{}(key) % buckets_.size();
}

} // namespace ninja
'@

Add-File -RelPath 'include/hash_map.h' -Content @'
#ifndef HASH_MAP_H
#define HASH_MAP_H

#include <string>
#include <vector>
#include <list>
#include <utility>
#include <cstddef>

namespace ninja {

class HashMap {
public:
    explicit HashMap(size_t bucketCount = 16);
    void insert(const std::string& key, double value);
    double get(const std::string& key) const;
    bool contains(const std::string& key) const;
    void remove(const std::string& key);
    size_t size() const;
    bool empty() const;
    void clear();
    std::vector<std::string> keys() const;
    double loadFactor() const;

private:
    std::vector<std::list<std::pair<std::string, double>>> buckets_;
    size_t size_ = 0;
    size_t hash(const std::string& key) const;
};

} // namespace ninja

#endif // HASH_MAP_H
'@

Add-File -RelPath 'src/linked_list.cpp' -Content @'
#include "linked_list.h"
#include <stdexcept>
#include <sstream>

namespace ninja {

LinkedList::LinkedList() : head_(nullptr), tail_(nullptr), size_(0) {}

LinkedList::~LinkedList() { clear(); }

void LinkedList::pushFront(double value) {
    Node* node = new Node{value, head_, nullptr};
    if (head_) head_->prev = node;
    head_ = node;
    if (!tail_) tail_ = node;
    size_++;
}

void LinkedList::pushBack(double value) {
    Node* node = new Node{value, nullptr, tail_};
    if (tail_) tail_->next = node;
    tail_ = node;
    if (!head_) head_ = node;
    size_++;
}

double LinkedList::popFront() {
    if (!head_) throw std::runtime_error("Empty list");
    Node* node = head_;
    double val = node->value;
    head_ = head_->next;
    if (head_) head_->prev = nullptr;
    else tail_ = nullptr;
    delete node;
    size_--;
    return val;
}

double LinkedList::popBack() {
    if (!tail_) throw std::runtime_error("Empty list");
    Node* node = tail_;
    double val = node->value;
    tail_ = tail_->prev;
    if (tail_) tail_->next = nullptr;
    else head_ = nullptr;
    delete node;
    size_--;
    return val;
}

double LinkedList::front() const {
    if (!head_) throw std::runtime_error("Empty list");
    return head_->value;
}

double LinkedList::back() const {
    if (!tail_) throw std::runtime_error("Empty list");
    return tail_->value;
}

size_t LinkedList::size() const { return size_; }

bool LinkedList::empty() const { return size_ == 0; }

void LinkedList::clear() {
    Node* current = head_;
    while (current) {
        Node* next = current->next;
        delete current;
        current = next;
    }
    head_ = tail_ = nullptr;
    size_ = 0;
}

bool LinkedList::contains(double value) const {
    Node* current = head_;
    while (current) {
        if (current->value == value) return true;
        current = current->next;
    }
    return false;
}

void LinkedList::reverse() {
    Node* current = head_;
    while (current) {
        Node* temp = current->next;
        current->next = current->prev;
        current->prev = temp;
        current = temp;
    }
    Node* temp = head_;
    head_ = tail_;
    tail_ = temp;
}

std::string LinkedList::toString() const {
    std::ostringstream oss;
    oss << "[";
    Node* current = head_;
    while (current) {
        oss << current->value;
        if (current->next) oss << " -> ";
        current = current->next;
    }
    oss << "]";
    return oss.str();
}

} // namespace ninja
'@

Add-File -RelPath 'include/linked_list.h' -Content @'
#ifndef LINKED_LIST_H
#define LINKED_LIST_H

#include <string>
#include <cstddef>

namespace ninja {

class LinkedList {
public:
    LinkedList();
    ~LinkedList();

    void pushFront(double value);
    void pushBack(double value);
    double popFront();
    double popBack();
    double front() const;
    double back() const;
    size_t size() const;
    bool empty() const;
    void clear();
    bool contains(double value) const;
    void reverse();
    std::string toString() const;

private:
    struct Node {
        double value;
        Node* next;
        Node* prev;
    };
    Node* head_;
    Node* tail_;
    size_t size_;
};

} // namespace ninja

#endif // LINKED_LIST_H
'@

Commit-As -Author 'dave' -Message 'Add HashMap and LinkedList data structures' -Date '2025-07-06T10:00:00.000000Z'

# r34: eve - sorting と string_algorithm
Add-File -RelPath 'src/sorting.cpp' -Content @'
#include "sorting.h"
#include <algorithm>
#include <functional>
#include <cstdlib>

namespace ninja {
namespace sorting {

void bubbleSort(std::vector<double>& arr) {
    size_t n = arr.size();
    for (size_t i = 0; i < n - 1; ++i) {
        bool swapped = false;
        for (size_t j = 0; j < n - i - 1; ++j) {
            if (arr[j] > arr[j+1]) {
                std::swap(arr[j], arr[j+1]);
                swapped = true;
            }
        }
        if (!swapped) break;
    }
}

void insertionSort(std::vector<double>& arr) {
    for (size_t i = 1; i < arr.size(); ++i) {
        double key = arr[i];
        int j = static_cast<int>(i) - 1;
        while (j >= 0 && arr[j] > key) {
            arr[j+1] = arr[j];
            --j;
        }
        arr[j+1] = key;
    }
}

void selectionSort(std::vector<double>& arr) {
    size_t n = arr.size();
    for (size_t i = 0; i < n - 1; ++i) {
        size_t minIdx = i;
        for (size_t j = i + 1; j < n; ++j) {
            if (arr[j] < arr[minIdx]) minIdx = j;
        }
        if (minIdx != i) std::swap(arr[i], arr[minIdx]);
    }
}

void mergeSort(std::vector<double>& arr) {
    if (arr.size() <= 1) return;
    size_t mid = arr.size() / 2;
    std::vector<double> left(arr.begin(), arr.begin() + mid);
    std::vector<double> right(arr.begin() + mid, arr.end());
    mergeSort(left);
    mergeSort(right);
    size_t i = 0, j = 0, k = 0;
    while (i < left.size() && j < right.size()) {
        arr[k++] = (left[i] <= right[j]) ? left[i++] : right[j++];
    }
    while (i < left.size()) arr[k++] = left[i++];
    while (j < right.size()) arr[k++] = right[j++];
}

void quickSort(std::vector<double>& arr) {
    quickSortHelper(arr, 0, static_cast<int>(arr.size()) - 1);
}

void quickSortHelper(std::vector<double>& arr, int low, int high) {
    if (low >= high) return;
    int pivotIdx = partition(arr, low, high);
    quickSortHelper(arr, low, pivotIdx - 1);
    quickSortHelper(arr, pivotIdx + 1, high);
}

int partition(std::vector<double>& arr, int low, int high) {
    double pivot = arr[high];
    int i = low - 1;
    for (int j = low; j < high; ++j) {
        if (arr[j] <= pivot) {
            ++i;
            std::swap(arr[i], arr[j]);
        }
    }
    std::swap(arr[i+1], arr[high]);
    return i + 1;
}

void heapSort(std::vector<double>& arr) {
    int n = static_cast<int>(arr.size());
    for (int i = n / 2 - 1; i >= 0; --i) heapify(arr, n, i);
    for (int i = n - 1; i > 0; --i) {
        std::swap(arr[0], arr[i]);
        heapify(arr, i, 0);
    }
}

void heapify(std::vector<double>& arr, int n, int i) {
    int largest = i;
    int left = 2 * i + 1;
    int right = 2 * i + 2;
    if (left < n && arr[left] > arr[largest]) largest = left;
    if (right < n && arr[right] > arr[largest]) largest = right;
    if (largest != i) {
        std::swap(arr[i], arr[largest]);
        heapify(arr, n, largest);
    }
}

bool isSorted(const std::vector<double>& arr) {
    for (size_t i = 1; i < arr.size(); ++i) {
        if (arr[i] < arr[i-1]) return false;
    }
    return true;
}

} // namespace sorting
} // namespace ninja
'@

Add-File -RelPath 'include/sorting.h' -Content @'
#ifndef SORTING_H
#define SORTING_H

#include <vector>

namespace ninja {
namespace sorting {

void bubbleSort(std::vector<double>& arr);
void insertionSort(std::vector<double>& arr);
void selectionSort(std::vector<double>& arr);
void mergeSort(std::vector<double>& arr);
void quickSort(std::vector<double>& arr);
void heapSort(std::vector<double>& arr);
bool isSorted(const std::vector<double>& arr);

void quickSortHelper(std::vector<double>& arr, int low, int high);
int partition(std::vector<double>& arr, int low, int high);
void heapify(std::vector<double>& arr, int n, int i);

} // namespace sorting
} // namespace ninja

#endif // SORTING_H
'@

Add-File -RelPath 'src/string_algorithm.cpp' -Content @'
#include "string_algorithm.h"
#include <algorithm>
#include <sstream>
#include <cctype>
#include <numeric>

namespace ninja {
namespace strutil {

std::string toUpper(const std::string& str) {
    std::string result = str;
    std::transform(result.begin(), result.end(), result.begin(), ::toupper);
    return result;
}

std::string toLower(const std::string& str) {
    std::string result = str;
    std::transform(result.begin(), result.end(), result.begin(), ::tolower);
    return result;
}

std::string reverse(const std::string& str) {
    return std::string(str.rbegin(), str.rend());
}

bool isPalindrome(const std::string& str) {
    size_t left = 0, right = str.size() - 1;
    while (left < right) {
        if (std::tolower(str[left]) != std::tolower(str[right])) return false;
        ++left; --right;
    }
    return true;
}

std::vector<std::string> split(const std::string& str, char delimiter) {
    std::vector<std::string> tokens;
    std::istringstream iss(str);
    std::string token;
    while (std::getline(iss, token, delimiter)) {
        tokens.push_back(token);
    }
    return tokens;
}

std::string join(const std::vector<std::string>& parts, const std::string& separator) {
    if (parts.empty()) return "";
    std::string result = parts[0];
    for (size_t i = 1; i < parts.size(); ++i) {
        result += separator + parts[i];
    }
    return result;
}

std::string repeat(const std::string& str, size_t count) {
    std::string result;
    result.reserve(str.size() * count);
    for (size_t i = 0; i < count; ++i) result += str;
    return result;
}

bool startsWith(const std::string& str, const std::string& prefix) {
    if (prefix.size() > str.size()) return false;
    return str.compare(0, prefix.size(), prefix) == 0;
}

bool endsWith(const std::string& str, const std::string& suffix) {
    if (suffix.size() > str.size()) return false;
    return str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string replace(const std::string& str, const std::string& from, const std::string& to) {
    std::string result = str;
    size_t pos = 0;
    while ((pos = result.find(from, pos)) != std::string::npos) {
        result.replace(pos, from.length(), to);
        pos += to.length();
    }
    return result;
}

size_t count(const std::string& str, const std::string& sub) {
    size_t cnt = 0, pos = 0;
    while ((pos = str.find(sub, pos)) != std::string::npos) {
        ++cnt;
        pos += sub.length();
    }
    return cnt;
}

std::string trim(const std::string& str) {
    auto start = str.find_first_not_of(" \t\n\r");
    if (start == std::string::npos) return "";
    auto end = str.find_last_not_of(" \t\n\r");
    return str.substr(start, end - start + 1);
}

std::string padLeft(const std::string& str, size_t width, char fillChar) {
    if (str.size() >= width) return str;
    return std::string(width - str.size(), fillChar) + str;
}

std::string padRight(const std::string& str, size_t width, char fillChar) {
    if (str.size() >= width) return str;
    return str + std::string(width - str.size(), fillChar);
}

} // namespace strutil
} // namespace ninja
'@

Add-File -RelPath 'include/string_algorithm.h' -Content @'
#ifndef STRING_ALGORITHM_H
#define STRING_ALGORITHM_H

#include <string>
#include <vector>
#include <cstddef>

namespace ninja {
namespace strutil {

std::string toUpper(const std::string& str);
std::string toLower(const std::string& str);
std::string reverse(const std::string& str);
bool isPalindrome(const std::string& str);
std::vector<std::string> split(const std::string& str, char delimiter);
std::string join(const std::vector<std::string>& parts, const std::string& separator);
std::string repeat(const std::string& str, size_t count);
bool startsWith(const std::string& str, const std::string& prefix);
bool endsWith(const std::string& str, const std::string& suffix);
std::string replace(const std::string& str, const std::string& from, const std::string& to);
size_t count(const std::string& str, const std::string& sub);
std::string trim(const std::string& str);
std::string padLeft(const std::string& str, size_t width, char fillChar = ' ');
std::string padRight(const std::string& str, size_t width, char fillChar = ' ');

} // namespace strutil
} // namespace ninja

#endif // STRING_ALGORITHM_H
'@

Commit-As -Author 'eve' -Message 'Add sorting algorithms and string utility functions' -Date '2025-07-07T11:00:00.000000Z'

# r35: alice - tree と priority_queue
Add-File -RelPath 'src/binary_tree.cpp' -Content @'
#include "binary_tree.h"
#include <queue>
#include <sstream>
#include <algorithm>
#include <cmath>

namespace ninja {

BinaryTree::BinaryTree() : root_(nullptr), size_(0) {}

BinaryTree::~BinaryTree() { destroyTree(root_); }

void BinaryTree::insert(double value) {
    root_ = insertNode(root_, value);
    size_++;
}

bool BinaryTree::search(double value) const {
    return searchNode(root_, value);
}

void BinaryTree::remove(double value) {
    root_ = removeNode(root_, value);
}

std::vector<double> BinaryTree::inorder() const {
    std::vector<double> result;
    inorderTraversal(root_, result);
    return result;
}

std::vector<double> BinaryTree::preorder() const {
    std::vector<double> result;
    preorderTraversal(root_, result);
    return result;
}

std::vector<double> BinaryTree::postorder() const {
    std::vector<double> result;
    postorderTraversal(root_, result);
    return result;
}

std::vector<double> BinaryTree::levelOrder() const {
    std::vector<double> result;
    if (!root_) return result;
    std::queue<TreeNode*> q;
    q.push(root_);
    while (!q.empty()) {
        TreeNode* node = q.front(); q.pop();
        result.push_back(node->value);
        if (node->left) q.push(node->left);
        if (node->right) q.push(node->right);
    }
    return result;
}

size_t BinaryTree::height() const { return heightOf(root_); }
size_t BinaryTree::size() const { return size_; }
bool BinaryTree::empty() const { return size_ == 0; }

double BinaryTree::minValue() const {
    if (!root_) throw std::runtime_error("Empty tree");
    TreeNode* node = root_;
    while (node->left) node = node->left;
    return node->value;
}

double BinaryTree::maxValue() const {
    if (!root_) throw std::runtime_error("Empty tree");
    TreeNode* node = root_;
    while (node->right) node = node->right;
    return node->value;
}

BinaryTree::TreeNode* BinaryTree::insertNode(TreeNode* node, double value) {
    if (!node) return new TreeNode{value, nullptr, nullptr};
    if (value < node->value) node->left = insertNode(node->left, value);
    else if (value > node->value) node->right = insertNode(node->right, value);
    return node;
}

bool BinaryTree::searchNode(TreeNode* node, double value) const {
    if (!node) return false;
    if (std::abs(node->value - value) < 1e-9) return true;
    if (value < node->value) return searchNode(node->left, value);
    return searchNode(node->right, value);
}

BinaryTree::TreeNode* BinaryTree::removeNode(TreeNode* node, double value) {
    if (!node) return nullptr;
    if (value < node->value) { node->left = removeNode(node->left, value); }
    else if (value > node->value) { node->right = removeNode(node->right, value); }
    else {
        if (!node->left) { TreeNode* r = node->right; delete node; size_--; return r; }
        if (!node->right) { TreeNode* l = node->left; delete node; size_--; return l; }
        TreeNode* succ = node->right;
        while (succ->left) succ = succ->left;
        node->value = succ->value;
        node->right = removeNode(node->right, succ->value);
    }
    return node;
}

void BinaryTree::inorderTraversal(TreeNode* node, std::vector<double>& result) const {
    if (!node) return;
    inorderTraversal(node->left, result);
    result.push_back(node->value);
    inorderTraversal(node->right, result);
}

void BinaryTree::preorderTraversal(TreeNode* node, std::vector<double>& result) const {
    if (!node) return;
    result.push_back(node->value);
    preorderTraversal(node->left, result);
    preorderTraversal(node->right, result);
}

void BinaryTree::postorderTraversal(TreeNode* node, std::vector<double>& result) const {
    if (!node) return;
    postorderTraversal(node->left, result);
    postorderTraversal(node->right, result);
    result.push_back(node->value);
}

size_t BinaryTree::heightOf(TreeNode* node) const {
    if (!node) return 0;
    return 1 + std::max(heightOf(node->left), heightOf(node->right));
}

void BinaryTree::destroyTree(TreeNode* node) {
    if (!node) return;
    destroyTree(node->left);
    destroyTree(node->right);
    delete node;
}

} // namespace ninja
'@

Add-File -RelPath 'include/binary_tree.h' -Content @'
#ifndef BINARY_TREE_H
#define BINARY_TREE_H

#include <vector>
#include <cstddef>

namespace ninja {

class BinaryTree {
public:
    BinaryTree();
    ~BinaryTree();

    void insert(double value);
    bool search(double value) const;
    void remove(double value);

    std::vector<double> inorder() const;
    std::vector<double> preorder() const;
    std::vector<double> postorder() const;
    std::vector<double> levelOrder() const;

    size_t height() const;
    size_t size() const;
    bool empty() const;
    double minValue() const;
    double maxValue() const;

private:
    struct TreeNode {
        double value;
        TreeNode* left;
        TreeNode* right;
    };

    TreeNode* root_;
    size_t size_;

    TreeNode* insertNode(TreeNode* node, double value);
    bool searchNode(TreeNode* node, double value) const;
    TreeNode* removeNode(TreeNode* node, double value);
    void inorderTraversal(TreeNode* node, std::vector<double>& result) const;
    void preorderTraversal(TreeNode* node, std::vector<double>& result) const;
    void postorderTraversal(TreeNode* node, std::vector<double>& result) const;
    size_t heightOf(TreeNode* node) const;
    void destroyTree(TreeNode* node);
};

} // namespace ninja

#endif // BINARY_TREE_H
'@

Commit-As -Author 'alice' -Message 'Add BinaryTree (BST) with traversals and balancing' -Date '2025-07-08T09:00:00.000000Z'

# r36-r40: CMakeLists.txt の段階的更新 + ドキュメント追加 + 小規模修正
# r36: bob - CMakeLists.txt 更新
$cmake = Get-Content (Join-Path $WcDir 'CMakeLists.txt') -Raw
$cmake = $cmake -replace 'project\(NinjaCalc VERSION 1.1.0', 'project(NinjaCalc VERSION 2.0.0'
$cmake += @'

# New modules
add_library(ninja_math STATIC src/math_functions.cpp src/matrix.cpp src/complex_number.cpp)
target_include_directories(ninja_math PRIVATE include)

add_library(ninja_data STATIC src/graph.cpp src/hash_map.cpp src/linked_list.cpp src/binary_tree.cpp)
target_include_directories(ninja_data PRIVATE include)

add_library(ninja_algo STATIC src/sorting.cpp src/string_algorithm.cpp src/signal_processor.cpp)
target_include_directories(ninja_algo PRIVATE include)
'@
Write-File -RelPath 'CMakeLists.txt' -Content $cmake
Commit-As -Author 'bob' -Message 'Update CMakeLists.txt to v2.0.0 with new library targets' -Date '2025-07-09T10:00:00.000000Z'

# r37: charlie - CHANGELOG 追加
Add-File -RelPath 'CHANGELOG.md' -Content @'
# Changelog

## [2.0.0] - 2025-07-09

### Added
- Matrix class with linear algebra operations
- Complex number support
- BigInt arbitrary precision arithmetic
- Graph class with BFS, DFS, Dijkstra
- Vector3D with cross product and projection
- SignalProcessor with filters and generators
- HashMap and LinkedList data structures
- BinaryTree (BST) implementation
- Sorting algorithms collection
- String utility functions
- Expression tree with simplification
- Advanced tokenizer with function support
- Config file reader

### Changed
- Bumped version to 2.0.0
- Improved error messages in parser
- Renamed utils to string_utils

## [1.1.0] - 2025-06-20

### Added
- Modulo operator support
- Calculation history
- Formatter with multiple output styles
- Help command in REPL

### Fixed
- Leading decimal point parsing
- Calculator reset notification

## [1.0.0] - 2025-06-01

### Added
- Initial calculator implementation
- Basic arithmetic operations
- Parentheses grouping
'@
Commit-As -Author 'charlie' -Message 'docs: Add CHANGELOG.md for version history' -Date '2025-07-10T09:00:00.000000Z'

# r38: dave - Doxyfile 追加
Add-File -RelPath 'Doxyfile' -Content @'
PROJECT_NAME           = "NinjaCalc"
PROJECT_NUMBER         = 2.0.0
PROJECT_BRIEF          = "A comprehensive C++ math library and calculator"
OUTPUT_DIRECTORY       = docs/api
INPUT                  = src include
FILE_PATTERNS          = *.cpp *.h
RECURSIVE              = YES
GENERATE_HTML          = YES
GENERATE_LATEX         = NO
EXTRACT_ALL            = YES
EXTRACT_PRIVATE        = YES
EXTRACT_STATIC         = YES
SOURCE_BROWSER         = YES
INLINE_SOURCES         = YES
HAVE_DOT               = YES
CALL_GRAPH             = YES
CALLER_GRAPH           = YES
CLASS_DIAGRAMS         = YES
COLLABORATION_GRAPH    = YES
UML_LOOK               = YES
DOT_IMAGE_FORMAT       = svg
INTERACTIVE_SVG        = YES
'@
Commit-As -Author 'dave' -Message 'Add Doxyfile for API documentation generation' -Date '2025-07-11T14:00:00.000000Z'

# r39: eve - .clang-format 追加
Add-File -RelPath '.clang-format' -Content @'
---
Language: Cpp
BasedOnStyle: Google
IndentWidth: 4
ColumnLimit: 100
AllowShortFunctionsOnASingleLine: None
AllowShortIfStatementsOnASingleLine: Never
AllowShortLoopsOnASingleLine: false
BreakBeforeBraces: Attach
PointerAlignment: Left
SpaceAfterCStyleCast: false
SpacesInParentheses: false
IncludeBlocks: Regroup
SortIncludes: true
AlwaysBreakTemplateDeclarations: Yes
NamespaceIndentation: None
FixNamespaceComments: true
---
'@
Commit-As -Author 'eve' -Message 'Add .clang-format configuration for code style' -Date '2025-07-12T10:00:00.000000Z'

# r40: alice - LICENSE ファイル追加
Add-File -RelPath 'LICENSE' -Content @'
MIT License

Copyright (c) 2025 NinjaCalc Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@
Commit-As -Author 'alice' -Message 'Add MIT LICENSE file' -Date '2025-07-13T09:00:00.000000Z'

# ---------- Phase 2: 反復的な修正コミット (r41 〜 r440) ----------
# 複数著者が既存ファイルを繰り返し修正し、blame/LCS の負荷を最大化する
Write-Host "  [Phase 2] 反復修正コミット生成 (r41 〜 r440)..." -ForegroundColor Yellow

# 修正対象となるソースファイル一覧 (ヘッダーと実装のペア)
$sourceFiles = @(
    'src/calculator.cpp',
    'src/parser.cpp',
    'src/string_utils.cpp',
    'src/math_functions.cpp',
    'src/matrix.cpp',
    'src/config.cpp',
    'src/complex_number.cpp',
    'src/expression_tree.cpp',
    'src/tokenizer.cpp',
    'src/bigint.cpp',
    'src/graph.cpp',
    'src/vector3d.cpp',
    'src/signal_processor.cpp',
    'src/hash_map.cpp',
    'src/linked_list.cpp',
    'src/sorting.cpp',
    'src/string_algorithm.cpp',
    'src/binary_tree.cpp',
    'src/formatter.cpp',
    'src/main.cpp'
)

$headerFiles = @(
    'include/calculator.h',
    'include/parser.h',
    'include/string_utils.h',
    'include/math_functions.h',
    'include/matrix.h',
    'include/config.h',
    'include/complex_number.h',
    'include/expression_tree.h',
    'include/tokenizer.h',
    'include/bigint.h',
    'include/graph.h',
    'include/vector3d.h',
    'include/signal_processor.h',
    'include/hash_map.h',
    'include/linked_list.h',
    'include/sorting.h',
    'include/string_algorithm.h',
    'include/binary_tree.h',
    'include/formatter.h'
)

$testFiles = @(
    'tests/test_calculator.cpp',
    'tests/test_parser.cpp',
    'tests/test_math_functions.cpp',
    'tests/test_matrix.cpp',
    'tests/test_bigint.cpp',
    'tests/test_vector3d.cpp'
)

# コミットメッセージのテンプレート
$commitMessages = @(
    'Improve error handling in {module}',
    'fix: null pointer check in {module}',
    'Refactor {module} for better readability',
    'Add input validation to {module}',
    'Optimize performance of {module}',
    'fix: edge case in {module} (#bug)',
    'Update documentation comments in {module}',
    'Add bounds checking to {module}',
    'Improve const correctness in {module}',
    'hotfix: memory leak in {module}',
    'Simplify logic in {module}',
    'Add error logging to {module}',
    'Refactor {module} to reduce complexity',
    'fix: off-by-one error in {module}',
    'Improve exception messages in {module}',
    'Add assertion checks in {module}',
    'Reduce code duplication in {module}',
    'Update {module} for C++17 compatibility',
    'Add noexcept specifiers to {module}',
    'Improve numerical stability in {module}'
)

# コメント行のパターン (各コミットでファイル内容に挿入/変更する)
$commentPatterns = @(
    '    // Performance optimization: cache result',
    '    // TODO: consider thread safety',
    '    // Validated input parameters',
    '    // Edge case: handle empty input',
    '    // Refactored for clarity',
    '    // Bug fix: check boundary conditions',
    '    // Added null pointer guard',
    '    // Optimized inner loop',
    '    // Documentation: explain algorithm',
    '    // FIXME: review this logic',
    '    // Memory management improvement',
    '    // Exception safety guarantee',
    '    // Const correctness applied',
    '    // Bounds checking added',
    '    // Simplified control flow',
    '    // Logging added for diagnostics',
    '    // Assertion for precondition',
    '    // C++17 structured bindings',
    '    // Noexcept specification',
    '    // Numerical stability check'
)

# 基準日時
$baseDate = [datetime]'2025-07-14T08:00:00Z'

for ($i = 0; $i -lt 400; $i++)
{
    $revNum = $i + 41
    $authorIdx = $i % $authors.Count
    $author = $authors[$authorIdx]

    # コミット日時 (2時間ずつ進める)
    $commitDate = $baseDate.AddHours($i * 2).ToString('yyyy-MM-ddTHH:mm:ss.000000Z')

    # 修正対象ファイルを選択 (1〜3 ファイルを変更 = co-change)
    $fileCount = 1 + ($i % 3)
    $fileIndices = @()
    for ($f = 0; $f -lt $fileCount; $f++)
    {
        $idx = ($i * 7 + $f * 3) % $sourceFiles.Count
        if ($fileIndices -notcontains $idx)
        {
            $fileIndices += $idx
        }
    }

    # 各ファイルを修正
    foreach ($fIdx in $fileIndices)
    {
        $filePath = $sourceFiles[$fIdx]
        $fullPath = Join-Path $WcDir $filePath
        if (-not (Test-Path $fullPath)) { continue }

        $content = Get-Content $fullPath -Raw
        $lines = $content -split "`n"

        # 挿入位置を決定 (ファイルの中間あたり)
        $insertLine = [math]::Min($lines.Count - 2, [math]::Max(5, [int]($lines.Count * (0.3 + ($i % 5) * 0.1))))

        # 前回挿入したコメントがあれば置換、なければ新規挿入
        $commentIdx = $i % $commentPatterns.Count
        $prevCommentIdx = ($i - $authors.Count) % $commentPatterns.Count
        if ($prevCommentIdx -lt 0) { $prevCommentIdx += $commentPatterns.Count }

        $newComment = $commentPatterns[$commentIdx]
        $prevComment = $commentPatterns[$prevCommentIdx]

        $replaced = $false
        for ($li = 0; $li -lt $lines.Count; $li++)
        {
            if ($lines[$li].TrimEnd() -eq $prevComment.TrimEnd())
            {
                $lines[$li] = $newComment
                $replaced = $true
                break
            }
        }

        if (-not $replaced)
        {
            # 新しいコメント行を挿入
            $newLines = [System.Collections.ArrayList]::new($lines)
            $newLines.Insert($insertLine, $newComment)
            $lines = $newLines.ToArray()
        }

        $newContent = $lines -join "`n"
        Write-File -RelPath $filePath -Content $newContent
    }

    # ヘッダーファイルも同時に修正するケース (3 コミットに 1 回)
    if ($i % 3 -eq 0 -and $fileIndices.Count -gt 0)
    {
        $hIdx = $fileIndices[0]
        if ($hIdx -lt $headerFiles.Count)
        {
            $hPath = $headerFiles[$hIdx]
            $hFullPath = Join-Path $WcDir $hPath
            if (Test-Path $hFullPath)
            {
                $hContent = Get-Content $hFullPath -Raw
                # ヘッダーのコメントを更新
                $verComment = "// Version: r$revNum modification"
                if ($hContent -match '// Version: r\d+ modification')
                {
                    $hContent = $hContent -replace '// Version: r\d+ modification', $verComment
                }
                else
                {
                    # #endif の前に挿入
                    $hContent = $hContent -replace '(#endif)', "$verComment`n`$1"
                }
                Write-File -RelPath $hPath -Content $hContent
            }
        }
    }

    # テストファイルも修正するケース (5 コミットに 1 回)
    if ($i % 5 -eq 0)
    {
        $tIdx = $i % $testFiles.Count
        $tPath = $testFiles[$tIdx]
        $tFullPath = Join-Path $WcDir $tPath
        if (Test-Path $tFullPath)
        {
            $tContent = Get-Content $tFullPath -Raw
            $testComment = "// Test updated at r$revNum"
            if ($tContent -match '// Test updated at r\d+')
            {
                $tContent = $tContent -replace '// Test updated at r\d+', $testComment
            }
            else
            {
                $tContent = $testComment + "`n" + $tContent
            }
            Write-File -RelPath $tPath -Content $tContent
        }
    }

    # コミットメッセージ生成
    $msgIdx = $i % $commitMessages.Count
    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFiles[$fileIndices[0]])
    $msg = $commitMessages[$msgIdx] -replace '\{module\}', $moduleName

    Commit-As -Author $author -Message $msg -Date $commitDate

    # 進捗表示 (20 コミットごと)
    if (($i + 1) % 20 -eq 0)
    {
        Write-Host "    r$revNum 完了 ($($i + 1)/400)" -ForegroundColor DarkGray
    }
}

# ======================================================================
# 完了
# ======================================================================
$finalInfo = svn info --xml $repoUrl
$finalRev = ([xml]$finalInfo).info.entry.revision

Write-Host ""
Write-Host "=== テスト用 SVN リポジトリ作成完了！ ===" -ForegroundColor Green
Write-Host ""
Write-Host "リポジトリ URL: $repoUrl" -ForegroundColor Cyan
Write-Host "リビジョン範囲: r1 〜 r${finalRev}" -ForegroundColor Cyan
Write-Host ""
Write-Host "NarutoCode で分析するには:" -ForegroundColor Yellow
Write-Host "  .\NarutoCode.ps1 -RepoUrl '$repoUrl' -FromRev 1 -ToRev $finalRev -OutDir .\tests\fixtures\expected_output -EmitPlantUml" -ForegroundColor White
Write-Host ""
Write-Host "コミッター (5名):" -ForegroundColor Yellow
Write-Host "  alice, bob, charlie, dave, eve" -ForegroundColor White
Write-Host ""
Write-Host "ベンチマーク構成:" -ForegroundColor Yellow
Write-Host "  - r1〜r20: オリジナルテストコミット (多様なアクション)" -ForegroundColor White
Write-Host "  - r21〜r40: 新ファイル群追加 (ファイルツリー拡大)" -ForegroundColor White
Write-Host "  - r41〜r${finalRev}: 反復修正コミット (blame/LCS 負荷)" -ForegroundColor White
Write-Host ""
Write-Host "テスト対象の指標:" -ForegroundColor Yellow
Write-Host "  - A/M/D/R アクション    (r1,r3,r12,r13)" -ForegroundColor White
Write-Host "  - 同一箇所反復          (alice: calculator.cpp r3,r5,r14)" -ForegroundColor White
Write-Host "  - 自己相殺              (alice: debug log add r3 -> remove r14)" -ForegroundColor White
Write-Host "  - ping-pong             (alice->bob->alice: r3,r4,r5)" -ForegroundColor White
Write-Host "  - co-change             (r6: 4ファイル同時, r17: 2ファイル同時, r41+: 多数)" -ForegroundColor White
Write-Host "  - バイナリ変更          (r7,r15: logo.png)" -ForegroundColor White
Write-Host "  - fix/hotfix キーワード (r9,r18 + Phase 2 多数)" -ForegroundColor White
Write-Host "  - 高/低 churn           (r8: 高churn, r16: 集中編集)" -ForegroundColor White
Write-Host "  - リネーム              (r13: utils→string_utils)" -ForegroundColor White
Write-Host "  - 大量ファイル反復修正  (r41〜: 20ファイル×5著者)" -ForegroundColor White
