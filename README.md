Below is a high-level overview of how this diagnostics application works **without** going into the Flutter-specific UI or code details. It focuses on:

- The **data model** (what each record looks like in JSON).
- The **core API endpoints** used for fetching, acknowledging, resolving, and canceling diagnostics.
- The **advanced features** like search, filtering by categories, and toggling resolved/unresolved items.

---

# AiDA Advanced Diagnostics: Backend & Advanced Features

## Table of Contents
1. [Overview](#overview)
2. [Data Structure](#data-structure)
3. [Endpoints & API Calls](#endpoints--api-calls)
4. [Advanced Features](#advanced-features)
    - [Auto-Refresh & Polling](#auto-refresh--polling)
    - [Search & Filter](#search--filter)
    - [Acknowledge, Resolve, and Cancel](#acknowledge-resolve-and-cancel)
    - [Category Handling](#category-handling)
5. [Example JSON Payload](#example-json-payload)
6. [FAQ](#faq)

---

## 1. Overview

The **AiDA Advanced Diagnostics** system is designed to retrieve, display, and update diagnostic records in real time. Each record typically captures the evolution of a problem—its iterations, root cause, final fix, and status. Core operations include:

- **Fetching** a list of all diagnostic items from the server.
- **Acknowledging** an item (user is aware of or triaging it).
- **Resolving** an item (issue is considered resolved).
- **Canceling** an item (no longer relevant or forcibly stopped).

Although there is a user interface (UI) built in Flutter, this document focuses on **how the data is structured** and **which API calls are made** in order to interact with the backend.

---

## 2. Data Structure

Each record in the system is represented by an `AdvancedDiagnosticData` object. It includes:

| **Field**              | **Type**                                       | **Description**                                                                                            |
|------------------------|-----------------------------------------------|------------------------------------------------------------------------------------------------------------|
| `iterations`           | `List<AnalysisIteration>`                      | A history of steps taken to investigate the issue (each with a description and command).                   |
| `originalProblem`      | `String`                                       | The initial problem statement.                                                                             |
| `config`               | `AdvancedDiagnosticConfig`                     | Nested configuration (environment, project, tracking ID, hostname, and program).                            |
| `timestamp`            | `String`                                       | When the record was created or first observed (ISO 8601).                                                 |
| `finalFixDescription`  | `String?` (nullable)                           | A textual description of how the issue was finally fixed (if available).                                   |
| `acknowledgements`     | `List<Acknowledgement>`                        | List of user acknowledgments (user + timestamp).                                                           |
| `resolutionStatus`     | `ResolutionStatus?` (nullable)                | If present, indicates the record is **resolved** (includes who resolved it, and when).                     |
| `complete`             | `bool`                                         | Not used for filtering in the new approach, but indicates if the record was completed in older logic.      |
| `canceledProcess`      | `CanceledProcess?` (nullable)                 | If present, indicates the record was canceled (includes who canceled it, and when).                        |
| `categories`           | `List<String>`                                 | A list of category names relevant to the diagnostic.                                                       |
| `lastUpdated`          | `String?` (nullable)                           | Timestamp for the last update (ISO 8601).                                                                  |

**Helper models**:

1. **`AnalysisIteration`**  
   - `description: String`  
   - `command: String`

2. **`AdvancedDiagnosticConfig`**  
   - `environment: String`  
   - `project: String`  
   - `trackingId: String`  
   - `hostname: String`  
   - `program: String`

3. **`Acknowledgement`**  
   - `user: String`  
   - `timestamp: String` (UTC in ISO 8601)

4. **`ResolutionStatus`**  
   - `user: String`  
   - `timestamp: String` (UTC in ISO 8601)

5. **`CanceledProcess`**  
   - `user: String`  
   - `timestamp: String` (UTC in ISO 8601)

---

## 3. Endpoints & API Calls

Assuming the base URL is defined as `ENDPOINT`, the primary API calls are:

1. **Fetch All Records**  
   **Method**: `GET`  
   **Path**: `GET $ENDPOINT/advanced_diagnostic/items/`  
   **Purpose**: Retrieve a list (array) of all diagnostic records in JSON format.  
   **Headers**:  
   ```json
   {
     "Content-Type": "application/json",
     "Accept": "application/json",
     "X-Amzn-Mtls-Clientcert-Subject": "emailAddress=you@example.com"
   }
   ```
   - Adjust as needed for your environment.

2. **Acknowledge an Item**  
   **Method**: `POST`  
   **Path**: `POST $ENDPOINT/advanced_diagnostic/acknowledge_item/`  
   **Request Body** (JSON):  
   ```json
   {
     "tracking_id": "<string>"
   }
   ```
   **Purpose**: Appends a new acknowledgment to the record (logged by the server with the user/time).

3. **Resolve an Item**  
   **Method**: `POST`  
   **Path**: `POST $ENDPOINT/advanced_diagnostic/resolve_item/`  
   **Request Body** (JSON):  
   ```json
   {
     "tracking_id": "<string>"
   }
   ```
   **Purpose**: Sets the `resolution_status` for the given record (indicating it’s resolved).

4. **Cancel an Item**  
   **Method**: `POST`  
   **Path**: `POST $ENDPOINT/advanced_diagnostic/cancel_diagnostic_item/`  
   **Request Body** (JSON):  
   ```json
   {
     "tracking_id": "<string>"
   }
   ```
   **Purpose**: Sets the record as canceled (indicating it was no longer needed or forcibly stopped).

---

## 4. Advanced Features

Below are the **key features** the app implements above and beyond simple listing:

### Auto-Refresh & Polling

- The app periodically fetches the latest items from the server.  
- Users can configure a refresh interval (commonly 5, 10, 15, 30, or 60 seconds, or a custom value).  
- If the call fails, the app may show a user-facing warning. Otherwise, it updates the displayed list.

### Search & Filter

- Records can be **filtered** by:
  - **Search Query**: Matching the text in `hostname`, `program`, `originalProblem`, or the `rootCause` (i.e., last iteration description).  
  - **Resolved vs. Unresolved**: 
    - *Resolved items* have a non-null `resolutionStatus`.  
    - *Unresolved items* do not have `resolutionStatus` set.  
  - **Categories**: Items can contain multiple categories (strings) in their `categories` array. Selecting one or more categories filters the records that have **at least** one of those categories.

### Acknowledge, Resolve, and Cancel

1. **Acknowledge**  
   - Sent when a user claims or notes an item. The endpoint adds an acknowledgment object (user + timestamp) to that record’s `acknowledgements` list.

2. **Resolve**  
   - Marks the item as completed. Sets `resolutionStatus` with the user and current timestamp.

3. **Cancel**  
   - Indicates that the process was shut down or no longer needed. The `canceledProcess` field is populated in the record.

### Category Handling

- The app can display all available categories from the fetched records and count how many times each category appears.  
- Users can pick one or more categories, and only records intersecting those categories are shown.

---

## 5. Example JSON Payload

Below is a **truncated** example of what the server might return on `GET /advanced_diagnostic/items/`:

```json
[
  {
    "_source": {
      "problem": "System ABC failing to connect to DB",
      "iterations": [
        {
          "description": "Checked DB logs for downtime",
          "command": "SELECT status FROM logs WHERE..."
        },
        {
          "description": "Found firewall block",
          "command": "Update firewall rules"
        }
      ],
      "advanced_diagnostic_config": {
        "environment": "prod",
        "project": "ProjectX",
        "tracking_id": "ABC123",
        "hostname": "server1.prod.org",
        "program": "db-connector"
      },
      "timestamp": "2025-01-15T12:34:56Z",
      "final_fix_description": "Opened firewall port 3306 on server1",
      "acknowledgements": [
        {
          "user": "alice",
          "timestamp": "2025-01-15T12:45:00Z"
        }
      ],
      "resolution_status": {
        "user": "bob",
        "timestamp": "2025-01-15T13:10:00Z"
      },
      "complete": false,
      "canceled_process": null,
      "categories": ["Networking", "Database"],
      "lastUpdated": "2025-01-15T13:15:00Z"
    }
  },
  ...
]
```

From this structure, the front-end app transforms it into an internal model and provides the user with:

- **Root Cause**: The last iteration’s description, e.g. `"Found firewall block"`.  
- **Is Resolved**: Determined by whether `resolution_status` is present (non-null).

---

## 6. FAQ

1. **How do we integrate custom headers for authentication?**  
   - In the examples, we pass a header called `X-Amzn-Mtls-Clientcert-Subject`. You can add or modify headers as needed (e.g., `Authorization: Bearer <token>` for OAuth-based systems).

2. **Can we change the intervals for polling data?**  
   - Yes. The application supports dynamic intervals. Adjust as needed or disable polling if your use case calls for manual refresh.

3. **What if the record is both resolved and canceled?**  
   - Typically, these are exclusive states. The final status might be either `resolution_status` or `canceled_process`. The UI logic checks one or the other to determine overall state.

4. **Can we add extra fields to each record?**  
   - Absolutely. You can extend the `_source` JSON or add new classes in your server data model. The front-end can parse additional fields if needed.

5. **Installing the Models?**
   - ```bash
     mkdir -p /models && python3 -u -c "import os; from huggingface_hub import snapshot_download; snapshot_download('intfloat/e5-large-v2',local_dir='/models/embedding', use_auth_token=os.environ['HF_TOKEN']); snapshot_download(repo_id='kosbu/Llama-3.3-70B-Instruct-AWQ', local_dir='/models/llm', use_auth_token=os.environ['HF_TOKEN'])"

---

**Need more info?**  
- For any further questions about data structure or endpoints, please contact your backend/API team or refer to the official internal documentation.  
