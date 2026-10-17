import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Button, Input, Modal } from "../src/components/controls";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "../src/components/ui/dropdown-menu";
import "../src/styles.css";
import "../src/console.css";
import "../src/ui.css";
function Fixture() {
 const [open,setOpen]=useState(false), [result,setResult]=useState("");
 return <main style={{padding:40}}><form onSubmit={e=>{ e.preventDefault(); setResult(new FormData(e.currentTarget).get('name') as string); }}><label>Name<Input name="name" /></label><Button className="primary">Submit</Button><Button disabled>Disabled</Button></form><output role="status">{result}</output><Button onClick={()=>setOpen(true)}>Open dialog</Button>{open && <Modal title="Example dialog" onClose={()=>setOpen(false)}><h2>Example dialog</h2><Input aria-label="Dialog field" /><Button onClick={()=>setOpen(false)}>Close</Button></Modal>}<DropdownMenu><DropdownMenuTrigger asChild><Button>Actions</Button></DropdownMenuTrigger><DropdownMenuContent><DropdownMenuItem>Rename</DropdownMenuItem><DropdownMenuItem>Move</DropdownMenuItem></DropdownMenuContent></DropdownMenu><Button title="More information">Help</Button></main>;
}
createRoot(document.getElementById('root')!).render(<Fixture/>);
