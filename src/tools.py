import os
import subprocess


def read_code_from_repo(repo_name: str, branch: str, directory: str):
    # Clone the repository
    output_dir = "/"
    clone_cmd = f"mkdir -p {output_dir}{directory} && git clone -b {branch} git@github.com:{repo_name} {output_dir}{directory}"
    subprocess.run(clone_cmd, shell=True, check=True)

    # Initialize an empty list to store code snippets
    code_snippets = []

    clonedDirectory = f"{output_dir}{directory}"

    # Iterate through files in the cloned repository
    for root, dirs, files in os.walk(clonedDirectory):
        for file in files:
            file_path = os.path.join(root, file)

            # Skip files in the /ansible/vars/ path
            # if f"{clonedDirectory}/ansible/vars/" in file_path:
            #     continue

            # Include only specific file extensions
            if file.endswith(('.py', '.java', '.js', '.yml', '.yaml', '.j2', '.ts', '.html', '.scss', '.sbt', '.json',
                              '.service', '.conf', '.sh')):
                with open(file_path, 'r') as f:
                    code_snippets.append({"path": file_path, "text": f.read()})

    clean_cmd = f"rm -rf {output_dir}{directory}"
    subprocess.run(clean_cmd, shell=True, check=True)

    return code_snippets


async def code_related_questions(validity_check: str, repo_name: str):
    """
    This function handles queries related to code, infrastructure, or OpeniO program functionality, with an adaptable interface for broader use cases.
    Ues this function if the question asks how we use OpeniO, program functionality, or Cloud Computing infrastructure.

    Args:
        repo_name: Code repository name. (choices: ["oio4", "infrastructure_as_code"])
        validity_check: Is the question related to the programming or functionality of OpeniO or the infrastructure? (choices: ["yes", "no"])

    """


tool_list = [code_related_questions]
