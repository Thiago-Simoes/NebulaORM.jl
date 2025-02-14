## Funcionalidades Implementadas

### 1. Conexão com o Banco de Dados
- **1.1** Uso de variáveis de ambiente com DotEnv para configurar a conexão.

### 2. Criação e Migração de Tabelas
- **2.1** Função `migrate!` e macro `@Model` que criam os modelos e tabelas automaticamente.

### 3. Registro Global de Modelos
- Armazenamento dos metadados em um dicionário global.

### 4. Definição de Colunas e Restrições via Macros
- Macros para `@PrimaryKey`, `@AutoIncrement`, `@NotNull` e `@Unique`.

### 5. Operações CRUD Básicas
- Funções para `create`, `update`, `delete`, `findMany`, `findFirst`, `findUnique`, entre outras.

### 6. Conversão e Instanciação de Modelos
- Conversão dos resultados das queries para instâncias dos modelos.

### 7. Geração de UUID
- Função `generateUuid` para criar identificadores únicos.

---

## Funcionalidades a Implementar

### 1. Segurança e Prevenção de SQL Injection
- Implementar `prepared statements` ou sanitização dos inputs para evitar injeções.

### 2. Suporte a Transações
- Adicionar mecanismos de transação (início, `commit` e `rollback`) para operações atômicas.

### 3. Pooling de Conexões
- Implementar um `pool de conexões` para melhorar a performance e evitar sobrecarga no banco.

### 4. Tratamento e Logging de Erros
- Aprimorar o tratamento de exceções e adicionar `logs` para facilitar a depuração.

### 5. Expansão do Mapeamento de Tipos SQL para Julia
- Incluir suporte para mais tipos (ex.: `DATE`, `TIMESTAMP`, etc.).

### 6. Operações SQL Mais Complexas
- Suporte para `joins`, `filtros avançados`, `ordenação` e `paginação`.

### 7. Otimização para Grandes Volumes de Dados
- Revisar o uso de `DataFrames` e avaliar alternativas para performance em grandes datasets.

### 8. Revisão dos Efeitos Colaterais das Macros
- Ajustar a execução automática (como a chamada do `migrate!` na macro `@Model`) para evitar surpresas.

### 9. Sobrescrita de Funções do Base
- Repensar a sobrescrita de funções (ex.: `Base.filter`) para evitar conflitos com o ecossistema Julia.